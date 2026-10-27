require "json"

module GRPC
  # A parsed and validated service config
  # (https://github.com/grpc/grpc/blob/master/doc/service_config.md):
  # per-method settings (timeouts, wait-for-ready, message size limits,
  # retry and hedging policies), retry throttling and the load balancing
  # policy.
  #
  # ```
  # config = GRPC::ServiceConfig.parse(<<-JSON)
  #   {
  #     "loadBalancingConfig": [{"round_robin": {}}],
  #     "methodConfig": [{
  #       "name": [{"service": "helloworld.Greeter"}],
  #       "timeout": "2s",
  #       "retryPolicy": {
  #         "maxAttempts": 3, "initialBackoff": "0.1s", "maxBackoff": "1s",
  #         "backoffMultiplier": 2, "retryableStatusCodes": ["UNAVAILABLE"]
  #       }
  #     }],
  #     "retryThrottling": {"maxTokens": 10, "tokenRatio": 0.1}
  #   }
  #   JSON
  # channel = GRPC::Channel.new("dns:///greeter:50051", service_config: config)
  # ```
  #
  # Invalid configs raise `ServiceConfig::Error`.
  class ServiceConfig
    # Raised for malformed or invalid service configs.
    class Error < ArgumentError
    end

    # Retry and hedging attempts are capped at this value (gRFC A6).
    MAX_ATTEMPTS_LIMIT = 5

    # A method name selector: a service and method, a whole service
    # (`method` nil) or the default config (both nil).
    record MethodName, service : String?, method : String? do
      def to_s(io : IO) : Nil
        io << (service || "*") << '/' << (method || "*")
      end
    end

    # Retry policy of a method (gRFC A6).
    struct RetryPolicy
      getter max_attempts : Int32
      getter initial_backoff : Time::Span
      getter max_backoff : Time::Span
      getter backoff_multiplier : Float64
      getter retryable_status_codes : Set(StatusCode)

      def initialize(@max_attempts : Int32, @initial_backoff : Time::Span, @max_backoff : Time::Span,
                     @backoff_multiplier : Float64, @retryable_status_codes : Set(StatusCode))
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
      getter max_attempts : Int32
      getter hedging_delay : Time::Span
      getter non_fatal_status_codes : Set(StatusCode)

      def initialize(@max_attempts : Int32, @hedging_delay : Time::Span, @non_fatal_status_codes : Set(StatusCode))
      end
    end

    # Settings applying to the methods selected by `names`.
    class MethodConfig
      getter names : Array(MethodName)
      getter wait_for_ready : Bool?
      getter timeout : Time::Span?
      getter max_request_message_bytes : Int64?
      getter max_response_message_bytes : Int64?
      getter retry_policy : RetryPolicy?
      getter hedging_policy : HedgingPolicy?

      def initialize(@names : Array(MethodName), *, @wait_for_ready : Bool? = nil, @timeout : Time::Span? = nil,
                     @max_request_message_bytes : Int64? = nil, @max_response_message_bytes : Int64? = nil,
                     @retry_policy : RetryPolicy? = nil, @hedging_policy : HedgingPolicy? = nil)
      end
    end

    # Retry throttling parameters (gRFC A6).
    record RetryThrottling, max_tokens : Int32, token_ratio : Float64

    getter method_configs : Array(MethodConfig)
    getter retry_throttling : RetryThrottling?
    # The selected load balancing policy name and its config, if any.
    getter load_balancing_policy : String?
    getter load_balancing_config : JSON::Any?
    # The JSON the config was parsed from.
    getter json : String

    @by_name = {} of MethodName => MethodConfig

    def initialize(@json : String, @method_configs : Array(MethodConfig), @retry_throttling : RetryThrottling?,
                   @load_balancing_policy : String?, @load_balancing_config : JSON::Any?)
      @method_configs.each do |config|
        config.names.each do |name|
          raise Error.new("Duplicate method config name #{name}") if @by_name.has_key?(name)
          @by_name[name] = config
        end
      end
    end

    # The empty config.
    def self.empty : ServiceConfig
      parse("{}")
    end

    # Parses and validates a service config in JSON.
    def self.parse(json : String) : ServiceConfig
      root = begin
        JSON.parse(json)
      rescue e : JSON::ParseException
        raise Error.new("Invalid service config JSON: #{e.message}")
      end
      Parser.new(json, root).parse
    end

    # The config of the method *path* (`/package.Service/Method`): an exact
    # match, else the service's config, else the default config.
    def method_config(path : String) : MethodConfig?
      service, _, method = path.lchop('/').rpartition('/')
      @by_name[MethodName.new(service, method)]? ||
        @by_name[MethodName.new(service, nil)]? ||
        @by_name[MethodName.new(nil, nil)]?
    end

    # :nodoc:
    struct Parser
      def initialize(@json : String, @root : JSON::Any)
      end

      def parse : ServiceConfig
        object = @root.as_h? || raise Error.new("Service config must be a JSON object")
        method_configs = array(object["methodConfig"]?, "methodConfig").map_with_index do |entry, i|
          method_config(entry, "methodConfig[#{i}]")
        end
        throttling = object["retryThrottling"]?.try { |value| retry_throttling(value) }
        policy, lb_config = load_balancing(object)
        ServiceConfig.new(@json, method_configs, throttling, policy, lb_config)
      end

      private def load_balancing(object : Hash(String, JSON::Any)) : {String?, JSON::Any?}
        if configs = object["loadBalancingConfig"]?
          list = array(configs, "loadBalancingConfig")
          list.each_with_index do |entry, i|
            hash = entry.as_h?
            unless hash && hash.size == 1
              raise Error.new("loadBalancingConfig[#{i}] must be an object with exactly one policy")
            end
            name, config = hash.first
            if provider = LoadBalancer.provider(name)
              begin
                return {name, provider.parse_config(config)}
              rescue e : ArgumentError
                raise Error.new("Invalid #{name} config: #{e.message}")
              end
            end
          end
          raise Error.new("No supported policy in loadBalancingConfig (supported: #{LoadBalancer.names.join(", ")})")
        elsif policy = object["loadBalancingPolicy"]?
          name = policy.as_s?.try(&.downcase) || raise Error.new("loadBalancingPolicy must be a string")
          unless LoadBalancer.provider(name)
            raise Error.new("Unsupported loadBalancingPolicy #{name.inspect}")
          end
          {name, JSON::Any.new({} of String => JSON::Any)}
        else
          {nil, nil}
        end
      end

      private def method_config(entry : JSON::Any, where : String) : MethodConfig
        hash = entry.as_h? || raise Error.new("#{where} must be an object")
        names = array(hash["name"]?, "#{where}.name").map_with_index { |name, i| method_name(name, "#{where}.name[#{i}]") }
        retry_policy = hash["retryPolicy"]?.try { |value| retry_policy(value, "#{where}.retryPolicy") }
        hedging_policy = hash["hedgingPolicy"]?.try { |value| hedging_policy(value, "#{where}.hedgingPolicy") }
        if retry_policy && hedging_policy
          raise Error.new("#{where}: retryPolicy and hedgingPolicy are mutually exclusive")
        end
        MethodConfig.new(names,
          wait_for_ready: hash["waitForReady"]?.try { |value| bool(value, "#{where}.waitForReady") },
          timeout: hash["timeout"]?.try { |value| duration(value, "#{where}.timeout") },
          max_request_message_bytes: hash["maxRequestMessageBytes"]?.try { |value| size(value, "#{where}.maxRequestMessageBytes") },
          max_response_message_bytes: hash["maxResponseMessageBytes"]?.try { |value| size(value, "#{where}.maxResponseMessageBytes") },
          retry_policy: retry_policy, hedging_policy: hedging_policy)
      end

      private def method_name(entry : JSON::Any, where : String) : MethodName
        hash = entry.as_h? || raise Error.new("#{where} must be an object")
        service = hash["service"]?.try { |value| string(value, "#{where}.service") }
        method = hash["method"]?.try { |value| string(value, "#{where}.method") }
        service = nil if service.try &.empty?
        method = nil if method.try &.empty?
        raise Error.new("#{where}: a method requires a service") if method && service.nil?
        MethodName.new(service, method)
      end

      private def retry_policy(value : JSON::Any, where : String) : RetryPolicy
        hash = value.as_h? || raise Error.new("#{where} must be an object")
        max_attempts = max_attempts(hash, where)
        initial = positive_duration(required(hash, "initialBackoff", where), "#{where}.initialBackoff")
        max = positive_duration(required(hash, "maxBackoff", where), "#{where}.maxBackoff")
        multiplier = number(required(hash, "backoffMultiplier", where), "#{where}.backoffMultiplier")
        raise Error.new("#{where}.backoffMultiplier must be > 0") unless multiplier > 0
        codes = status_codes(required(hash, "retryableStatusCodes", where), "#{where}.retryableStatusCodes")
        raise Error.new("#{where}.retryableStatusCodes must not be empty") if codes.empty?
        RetryPolicy.new(max_attempts, initial, max, multiplier, codes)
      end

      private def hedging_policy(value : JSON::Any, where : String) : HedgingPolicy
        hash = value.as_h? || raise Error.new("#{where} must be an object")
        max_attempts = max_attempts(hash, where)
        delay = hash["hedgingDelay"]?.try { |d| duration(d, "#{where}.hedgingDelay") } || Time::Span.zero
        codes = hash["nonFatalStatusCodes"]?.try { |c| status_codes(c, "#{where}.nonFatalStatusCodes") } || Set(StatusCode).new
        HedgingPolicy.new(max_attempts, delay, codes)
      end

      private def max_attempts(hash : Hash(String, JSON::Any), where : String) : Int32
        value = required(hash, "maxAttempts", where)
        attempts = value.as_i64? || raise Error.new("#{where}.maxAttempts must be an integer")
        raise Error.new("#{where}.maxAttempts must be greater than 1") unless attempts > 1
        Math.min(attempts, MAX_ATTEMPTS_LIMIT.to_i64).to_i32
      end

      private def retry_throttling(value : JSON::Any) : RetryThrottling
        hash = value.as_h? || raise Error.new("retryThrottling must be an object")
        max_tokens = required(hash, "maxTokens", "retryThrottling").as_i64? || raise Error.new("retryThrottling.maxTokens must be an integer")
        raise Error.new("retryThrottling.maxTokens must be in (0, 1000]") unless 0 < max_tokens <= 1000
        ratio = number(required(hash, "tokenRatio", "retryThrottling"), "retryThrottling.tokenRatio")
        # Only three decimal places are significant.
        ratio = (ratio * 1000).floor / 1000
        raise Error.new("retryThrottling.tokenRatio must be > 0") unless ratio > 0
        RetryThrottling.new(max_tokens.to_i32, ratio)
      end

      private def status_codes(value : JSON::Any, where : String) : Set(StatusCode)
        set = Set(StatusCode).new
        array(value, where).each do |code|
          set << (ServiceConfig.parse_status_code(code) || raise Error.new("#{where}: invalid status code #{code.to_json}"))
        end
        set
      end

      private def required(hash : Hash(String, JSON::Any), key : String, where : String) : JSON::Any
        hash[key]? || raise Error.new("#{where}.#{key} is required")
      end

      private def array(value : JSON::Any?, where : String) : Array(JSON::Any)
        return [] of JSON::Any if value.nil?
        value.as_a? || raise Error.new("#{where} must be an array")
      end

      private def string(value : JSON::Any, where : String) : String
        value.as_s? || raise Error.new("#{where} must be a string")
      end

      private def bool(value : JSON::Any, where : String) : Bool
        result = value.as_bool?
        raise Error.new("#{where} must be a boolean") if result.nil?
        result
      end

      private def number(value : JSON::Any, where : String) : Float64
        value.as_f? || value.as_i64?.try(&.to_f) || raise Error.new("#{where} must be a number")
      end

      # A non-negative byte count (a JSON number, or a string as produced by
      # proto3 JSON for 64-bit integers).
      private def size(value : JSON::Any, where : String) : Int64
        result = value.as_i64? || value.as_s?.try(&.to_i64?)
        raise Error.new("#{where} must be a non-negative integer") unless result && result >= 0
        result
      end

      private def duration(value : JSON::Any, where : String) : Time::Span
        string = value.as_s? || raise Error.new("#{where} must be a duration string like \"1.5s\"")
        ServiceConfig.parse_duration(string) || raise Error.new("#{where}: invalid duration #{string.inspect}")
      end

      private def positive_duration(value : JSON::Any, where : String) : Time::Span
        span = duration(value, where)
        raise Error.new("#{where} must be > 0") unless span > Time::Span.zero
        span
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

    # Parses a status code given as a number or a (case-insensitive) name
    # like `"UNAVAILABLE"`.
    def self.parse_status_code(value : JSON::Any) : StatusCode?
      if number = value.as_i64?
        StatusCode.from_value?(number)
      elsif name = value.as_s?
        normalized = name.upcase
        StatusCode.values.find { |code| code.to_s.underscore.upcase == normalized }
      end
    end
  end
end
