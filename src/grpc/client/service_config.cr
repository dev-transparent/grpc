require "json"

module GRPC
  # A typed, validated service config
  # (https://github.com/grpc/grpc/blob/master/doc/service_config.md):
  # per-method settings (timeouts, wait-for-ready, message size limits,
  # retry and hedging policies), retry throttling and the load balancing
  # policy.
  #
  # Configs are `JSON::Serializable` and use gRPC's standard JSON format, so
  # they can be loaded from a file shared with other gRPC implementations:
  #
  # ```
  # config = GRPC::ServiceConfig.load("service_config.json")
  # config = GRPC::ServiceConfig.parse(%({"loadBalancingConfig": [{"round_robin": {}}]}))
  # ```
  #
  # or built in code:
  #
  # ```
  # config = GRPC::ServiceConfig.new(
  #   load_balancing_config: [GRPC::RoundRobinConfig.new] of GRPC::LoadBalancingConfig,
  #   method_configs: [
  #     GRPC::ServiceConfig::MethodConfig.new(
  #       names: [GRPC::ServiceConfig::MethodName.new("helloworld.Greeter")],
  #       timeout: 2.seconds,
  #       retry_policy: GRPC::ServiceConfig::RetryPolicy.new(
  #         max_attempts: 3, initial_backoff: 100.milliseconds, max_backoff: 1.second,
  #         backoff_multiplier: 2.0, retryable_status_codes: Set{GRPC::StatusCode::Unavailable})),
  #   ],
  #   retry_throttling: GRPC::ServiceConfig::RetryThrottling.new(max_tokens: 10, token_ratio: 0.1))
  # channel = GRPC::Channel.new("dns:///greeter:50051", service_config: config)
  # ```
  #
  # Invalid configs raise `ServiceConfig::Error`.
  class ServiceConfig
    include JSON::Serializable

    # Raised for malformed or invalid service configs.
    class Error < ArgumentError
    end

    # Retry and hedging attempts are capped at this value (gRFC A6).
    MAX_ATTEMPTS_LIMIT = 5

    # The deprecated `loadBalancingPolicy` field: the name of a built-in
    # policy. Prefer `loadBalancingConfig`.
    enum LoadBalancingPolicy
      PickFirst
      RoundRobin

      # The equivalent load balancing config.
      def to_config : LoadBalancingConfig
        case self
        in .pick_first?  then PickFirstConfig.new
        in .round_robin? then RoundRobinConfig.new
        end
      end

      # Parses `"ROUND_ROBIN"`, `"round_robin"`, `"pick_first"`, ...
      def self.new(pull : JSON::PullParser) : self
        name = pull.read_string
        parse?(name.delete('_')) || raise Error.new("Unsupported loadBalancingPolicy #{name.inspect}")
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s.underscore.upcase)
      end
    end

    # A method selector: a service and method, a whole service (`method`
    # nil) or the default config (both nil).
    struct MethodName
      include JSON::Serializable

      getter service : String?
      getter method : String?

      def initialize(@service : String? = nil, @method : String? = nil)
        validate
      end

      def after_initialize : Nil
        @service = nil if @service.try &.empty?
        @method = nil if @method.try &.empty?
        validate
      end

      def to_s(io : IO) : Nil
        io << (service || "*") << '/' << (method || "*")
      end

      private def validate : Nil
        raise Error.new("Method config name: a method requires a service") if @method && @service.nil?
      end
    end

    # Retry policy of a method (gRFC A6).
    struct RetryPolicy
      include JSON::Serializable

      # Total attempts, including the original (2..5; larger values are
      # capped at 5).
      @[JSON::Field(key: "maxAttempts")]
      getter max_attempts : Int32
      @[JSON::Field(key: "initialBackoff", converter: GRPC::ServiceConfig::DurationConverter)]
      getter initial_backoff : Time::Span
      @[JSON::Field(key: "maxBackoff", converter: GRPC::ServiceConfig::DurationConverter)]
      getter max_backoff : Time::Span
      @[JSON::Field(key: "backoffMultiplier")]
      getter backoff_multiplier : Float64
      @[JSON::Field(key: "retryableStatusCodes", converter: GRPC::ServiceConfig::StatusCodesConverter)]
      getter retryable_status_codes : Set(StatusCode)

      def initialize(*, @max_attempts : Int32, @initial_backoff : Time::Span, @max_backoff : Time::Span,
                     @backoff_multiplier : Float64, @retryable_status_codes : Set(StatusCode))
        after_initialize
      end

      def after_initialize : Nil
        @max_attempts = ServiceConfig.check_attempts(@max_attempts, "retryPolicy")
        ServiceConfig.check_positive(@initial_backoff, "retryPolicy.initialBackoff")
        ServiceConfig.check_positive(@max_backoff, "retryPolicy.maxBackoff")
        raise Error.new("retryPolicy.backoffMultiplier must be > 0") unless @backoff_multiplier > 0
        raise Error.new("retryPolicy.retryableStatusCodes must not be empty") if @retryable_status_codes.empty?
      end

      # The delay before retry number *retry* (1 for the first retry):
      # `min(initial * multiplier^(retry-1), max)` with +/-20% jitter.
      def backoff(retry : Int32, random : Random? = nil) : Time::Span
        base = @initial_backoff.total_seconds * (@backoff_multiplier ** (retry - 1))
        base = Math.min(base, @max_backoff.total_seconds)
        (base * (0.8 + (random ? random.rand : Random.rand) * 0.4)).seconds
      end
    end

    # Hedging policy of a method (gRFC A6).
    struct HedgingPolicy
      include JSON::Serializable

      @[JSON::Field(key: "maxAttempts")]
      getter max_attempts : Int32
      @[JSON::Field(key: "hedgingDelay", converter: GRPC::ServiceConfig::DurationConverter)]
      getter hedging_delay : Time::Span = Time::Span.zero
      @[JSON::Field(key: "nonFatalStatusCodes", converter: GRPC::ServiceConfig::StatusCodesConverter)]
      getter non_fatal_status_codes : Set(StatusCode) = Set(StatusCode).new

      def initialize(*, @max_attempts : Int32, @hedging_delay : Time::Span = Time::Span.zero,
                     @non_fatal_status_codes : Set(StatusCode) = Set(StatusCode).new)
        after_initialize
      end

      def after_initialize : Nil
        @max_attempts = ServiceConfig.check_attempts(@max_attempts, "hedgingPolicy")
        raise Error.new("hedgingPolicy.hedgingDelay must not be negative") if @hedging_delay < Time::Span.zero
      end
    end

    # Settings applying to the methods selected by `names`.
    class MethodConfig
      include JSON::Serializable

      @[JSON::Field(key: "name")]
      getter names : Array(MethodName) = [] of MethodName
      @[JSON::Field(key: "waitForReady")]
      getter wait_for_ready : Bool?
      @[JSON::Field(converter: GRPC::ServiceConfig::DurationConverter)]
      getter timeout : Time::Span?
      @[JSON::Field(key: "maxRequestMessageBytes", converter: GRPC::ServiceConfig::ByteSizeConverter)]
      getter max_request_message_bytes : Int64?
      @[JSON::Field(key: "maxResponseMessageBytes", converter: GRPC::ServiceConfig::ByteSizeConverter)]
      getter max_response_message_bytes : Int64?
      @[JSON::Field(key: "retryPolicy")]
      getter retry_policy : RetryPolicy?
      @[JSON::Field(key: "hedgingPolicy")]
      getter hedging_policy : HedgingPolicy?

      def initialize(*, @names : Array(MethodName), @wait_for_ready : Bool? = nil, @timeout : Time::Span? = nil,
                     @max_request_message_bytes : Int64? = nil, @max_response_message_bytes : Int64? = nil,
                     @retry_policy : RetryPolicy? = nil, @hedging_policy : HedgingPolicy? = nil)
        after_initialize
      end

      def after_initialize : Nil
        if @retry_policy && @hedging_policy
          raise Error.new("Method config #{@names.join(", ")}: retryPolicy and hedgingPolicy are mutually exclusive")
        end
        if (timeout = @timeout) && timeout < Time::Span.zero
          raise Error.new("Method config #{@names.join(", ")}: timeout must not be negative")
        end
      end
    end

    # Retry throttling parameters (gRFC A6).
    struct RetryThrottling
      include JSON::Serializable

      # Token bucket size, in (0, 1000].
      @[JSON::Field(key: "maxTokens")]
      getter max_tokens : Int32
      # Tokens added per successful call (> 0; only three decimal places
      # are significant).
      @[JSON::Field(key: "tokenRatio")]
      getter token_ratio : Float64

      def initialize(*, @max_tokens : Int32, @token_ratio : Float64)
        after_initialize
      end

      def after_initialize : Nil
        raise Error.new("retryThrottling.maxTokens must be in (0, 1000]") unless 0 < @max_tokens <= 1000
        @token_ratio = (@token_ratio * 1000).floor / 1000
        raise Error.new("retryThrottling.tokenRatio must be > 0") unless @token_ratio > 0
      end
    end

    # Per-method configs.
    @[JSON::Field(key: "methodConfig")]
    getter method_configs : Array(MethodConfig) = [] of MethodConfig

    @[JSON::Field(key: "retryThrottling")]
    getter retry_throttling : RetryThrottling?

    # Load balancing policies in order of preference; the first one this
    # client supports is used (see `#load_balancing`).
    @[JSON::Field(key: "loadBalancingConfig", converter: GRPC::ServiceConfig::LoadBalancingConfigsConverter)]
    getter load_balancing_config : Array(LoadBalancingConfig)?

    # The deprecated policy name, used when `load_balancing_config` is not
    # set.
    @[JSON::Field(key: "loadBalancingPolicy")]
    getter load_balancing_policy : LoadBalancingPolicy?

    @[JSON::Field(ignore: true)]
    @by_name = {} of MethodName => MethodConfig

    def initialize(*, @method_configs : Array(MethodConfig) = [] of MethodConfig,
                   @retry_throttling : RetryThrottling? = nil,
                   @load_balancing_config : Array(LoadBalancingConfig)? = nil,
                   @load_balancing_policy : LoadBalancingPolicy? = nil)
      after_initialize
    end

    def after_initialize : Nil
      @by_name = {} of MethodName => MethodConfig
      @method_configs.each do |config|
        config.names.each do |name|
          raise Error.new("Duplicate method config name #{name}") if @by_name.has_key?(name)
          @by_name[name] = config
        end
      end
      if (configs = @load_balancing_config) && !configs.empty? && configs.all?(UnsupportedLoadBalancingConfig)
        names = configs.map(&.policy_name).join(", ")
        raise Error.new("No supported policy in loadBalancingConfig (#{names}; supported: #{LoadBalancer.names.join(", ")})")
      end
    end

    # The empty config.
    def self.empty : ServiceConfig
      new
    end

    # Parses and validates a service config in JSON.
    def self.parse(json : String) : ServiceConfig
      from_json(json)
    rescue e : JSON::SerializableError
      raise Error.new("Invalid service config: #{e.message}")
    rescue e : JSON::ParseException
      raise Error.new("Invalid service config JSON: #{e.message}")
    end

    # Loads a service config from a JSON file.
    def self.load(path : String | Path) : ServiceConfig
      parse(File.read(path))
    end

    # The load balancing policy to use: the first supported entry of
    # `load_balancing_config`, else `load_balancing_policy`, else `nil`
    # (the channel's default).
    def load_balancing : LoadBalancingConfig?
      if configs = @load_balancing_config
        configs.find { |config| !config.is_a?(UnsupportedLoadBalancingConfig) }
      else
        @load_balancing_policy.try(&.to_config)
      end
    end

    # The config of the method *path* (`/package.Service/Method`): an exact
    # match, else the service's config, else the default config.
    def method_config(path : String) : MethodConfig?
      service, _, method = path.lchop('/').rpartition('/')
      @by_name[MethodName.new(service, method)]? ||
        @by_name[MethodName.new(service, nil)]? ||
        @by_name[MethodName.new(nil, nil)]?
    end

    def ==(other : ServiceConfig) : Bool
      to_json == other.to_json
    end

    # --- Validation helpers ---

    # :nodoc:
    def self.check_attempts(attempts : Int32, where : String) : Int32
      raise Error.new("#{where}.maxAttempts must be greater than 1") unless attempts > 1
      Math.min(attempts, MAX_ATTEMPTS_LIMIT)
    end

    # :nodoc:
    def self.check_positive(span : Time::Span, where : String) : Nil
      raise Error.new("#{where} must be > 0") unless span > Time::Span.zero
    end

    # --- Converters ---

    # Proto3 JSON durations: `"1.5s"`, `"0.000001s"`.
    module DurationConverter
      def self.from_json(pull : JSON::PullParser) : Time::Span
        location = pull.location
        unless pull.kind.string?
          raise Error.new("Expected a duration string like \"1.5s\" at line #{location[0]}, column #{location[1]}")
        end
        string = pull.read_string
        ServiceConfig.parse_duration(string) || raise Error.new("Invalid duration #{string.inspect} at line #{location[0]}, column #{location[1]}")
      end

      def self.to_json(value : Time::Span, json : JSON::Builder) : Nil
        json.string(ServiceConfig.format_duration(value))
      end
    end

    # A non-negative byte count, as a JSON number or (proto3 JSON style for
    # 64-bit integers) a string.
    module ByteSizeConverter
      def self.from_json(pull : JSON::PullParser) : Int64
        value = case pull.kind
                when .int?    then pull.read_int
                when .string? then pull.read_string.to_i64?
                end
        raise Error.new("Message size must be a non-negative integer") unless value && value >= 0
        value
      end

      def self.to_json(value : Int64, json : JSON::Builder) : Nil
        json.number(value)
      end
    end

    # A set of status codes given as names (`"UNAVAILABLE"`, case
    # insensitive) or numbers.
    module StatusCodesConverter
      def self.from_json(pull : JSON::PullParser) : Set(StatusCode)
        set = Set(StatusCode).new
        pull.read_array do
          code = case pull.kind
                 when .int?    then StatusCode.from_value?(pull.read_int)
                 when .string? then ServiceConfig.status_code(pull.read_string)
                 else               pull.skip
                 end
          set << (code || raise Error.new("Invalid status code at line #{pull.location[0]}"))
        end
        set
      end

      def self.to_json(value : Set(StatusCode), json : JSON::Builder) : Nil
        json.array { value.each { |code| json.string(code.to_s.underscore.upcase) } }
      end
    end

    # `loadBalancingConfig`: a list of single-key objects `{"policy": {...}}`.
    module LoadBalancingConfigsConverter
      def self.from_json(pull : JSON::PullParser) : Array(LoadBalancingConfig)
        configs = [] of LoadBalancingConfig
        pull.read_array do
          entry = JSON::Any.new(pull)
          hash = entry.as_h?
          unless hash && hash.size == 1
            raise Error.new("Each loadBalancingConfig entry must be an object with exactly one policy")
          end
          name, value = hash.first
          configs << LoadBalancingConfig.parse(name, value)
        end
        configs
      end

      def self.to_json(value : Array(LoadBalancingConfig), json : JSON::Builder) : Nil
        json.array do
          value.each do |config|
            json.object { json.field(config.policy_name) { config.to_json(json) } }
          end
        end
      end
    end

    # Parses a proto3 JSON duration (`"1.5s"`, `"0.000001s"`, `"10s"`).
    def self.parse_duration(string : String) : Time::Span?
      match = /\A(\d+)(?:\.(\d{1,9}))?s\z/.match(string) || return nil
      seconds = match[1].to_i64? || return nil
      return nil if seconds > 315_576_000_000
      nanos = match[2]?.try(&.ljust(9, '0').to_i64) || 0_i64
      Time::Span.new(seconds: seconds, nanoseconds: nanos)
    end

    # Formats a duration as proto3 JSON (`"1.5s"`).
    def self.format_duration(span : Time::Span) : String
      seconds = span.total_seconds.to_i64
      nanos = span.nanoseconds
      return "#{seconds}s" if nanos == 0
      "#{seconds}.#{nanos.to_s.rjust(9, '0').rstrip('0')}s"
    end

    # Parses a status code name like `"UNAVAILABLE"` (case insensitive).
    def self.status_code(name : String) : StatusCode?
      normalized = name.upcase
      StatusCode.values.find { |code| code.to_s.underscore.upcase == normalized }
    end
  end

  # The configuration of a load balancing policy, as found in a service
  # config's `loadBalancingConfig` (`{"round_robin": {}}`). Built-in policies
  # have their own typed subclasses (`PickFirstConfig`, `RoundRobinConfig`);
  # custom policies parse their config into their own subclass in
  # `LoadBalancer::Provider#parse_config`.
  abstract class LoadBalancingConfig
    # The name of the policy, e.g. `"round_robin"`.
    abstract def policy_name : String

    abstract def to_json(json : JSON::Builder)

    # Parses the config of policy *name* with its registered provider. A
    # policy that is not registered yields an
    # `UnsupportedLoadBalancingConfig`, which is skipped when selecting the
    # policy.
    def self.parse(name : String, value : JSON::Any) : LoadBalancingConfig
      provider = LoadBalancer.provider(name)
      return UnsupportedLoadBalancingConfig.new(name, value) unless provider
      unless value.as_h?
        raise ServiceConfig::Error.new("The config of load balancing policy #{name} must be an object")
      end
      provider.parse_config(value)
    rescue e : JSON::SerializableError | JSON::ParseException | ArgumentError
      raise e if e.is_a?(ServiceConfig::Error)
      raise ServiceConfig::Error.new("Invalid #{name} config: #{e.message}")
    end
  end

  # Config of the `pick_first` policy.
  class PickFirstConfig < LoadBalancingConfig
    include JSON::Serializable

    # Randomize the address order on every resolver update (to spread
    # clients over servers).
    @[JSON::Field(key: "shuffleAddressList")]
    getter? shuffle_address_list : Bool = false

    def initialize(*, @shuffle_address_list : Bool = false)
    end

    def policy_name : String
      "pick_first"
    end
  end

  # Config of the `round_robin` policy (it has no options).
  class RoundRobinConfig < LoadBalancingConfig
    include JSON::Serializable

    def initialize
    end

    def policy_name : String
      "round_robin"
    end
  end

  # The config of a custom policy that does not define its own typed
  # config: the policy receives the raw JSON.
  class GenericLoadBalancingConfig < LoadBalancingConfig
    getter policy_name : String
    getter config : JSON::Any

    def initialize(@policy_name : String, @config : JSON::Any = JSON::Any.new({} of String => JSON::Any))
    end

    def to_json(json : JSON::Builder) : Nil
      @config.to_json(json)
    end
  end

  # A `loadBalancingConfig` entry for a policy this client does not support
  # (kept so the config round-trips; never selected).
  class UnsupportedLoadBalancingConfig < LoadBalancingConfig
    getter policy_name : String
    getter config : JSON::Any

    def initialize(@policy_name : String, @config : JSON::Any)
    end

    def to_json(json : JSON::Builder) : Nil
      @config.to_json(json)
    end
  end
end
