module GRPC
  # A virtual connection to a gRPC service. A channel resolves its target
  # into addresses (`Resolver`), keeps connections (`Subchannel`) to them
  # according to a load balancing policy (`LoadBalancer`) and spreads calls
  # over them. Connections are established lazily, re-established after
  # failures with exponential backoff, and released after `idle_timeout`
  # without calls.
  #
  # Targets (https://github.com/grpc/grpc/blob/master/doc/naming.md):
  #
  # * `"host:port"`, `"dns:///host:port"`: all addresses of `host` (port
  #   443 if omitted).
  # * `"ipv4:10.0.0.1:50051,10.0.0.2:50051"`, `"ipv6:[::1]:50051"`.
  # * `"unix:/path/to/socket"`, `"unix:///absolute/path"`.
  # * `"passthrough:///host:port"`: no resolution by gRPC.
  # * `"http://host:port"`, `"https://host:port"`: cleartext or TLS (ports
  #   default to 80 and 443).
  # * Any scheme of a registered `Resolver::Provider`.
  #
  # ```
  # channel = GRPC::Channel.new("dns:///greeter.internal:50051",
  #   credentials: GRPC::ChannelCredentials.tls(ca_file: "ca.pem"),
  #   service_config: %({"loadBalancingConfig": [{"round_robin": {}}]}))
  # client = Helloworld::Greeter::Client.new(channel)
  # ```
  #
  # Channels are safe to use from any number of fibers and threads.
  class Channel
    DEFAULT_USER_AGENT = "grpc-crystal/#{VERSION}"
    # Default limit of the per-call buffer of sent messages kept for retries.
    DEFAULT_PER_RPC_BUFFER_SIZE = 256 * 1024
    # Default limit of the retry buffers of all calls of a channel.
    DEFAULT_RETRY_BUFFER_SIZE = 16 * 1024 * 1024
    DEFAULT_IDLE_TIMEOUT      = 30.minutes

    getter target : String
    getter user_agent : String
    getter credentials : ChannelCredentials
    # The `:authority` of calls (and the TLS server name unless overridden).
    getter authority : String
    getter backoff : ConnectionBackoff
    getter keepalive : KeepaliveOptions?
    # Time without calls after which connections are released.
    getter idle_timeout : Time::Span?
    # Whether calls may be retried (retry and hedging policies, and
    # transparent retries).
    getter? retries_enabled : Bool
    # Limit of the sent messages buffered for retries, per call.
    getter per_rpc_buffer_size : Int32
    # Limit of the sent messages buffered for retries, for all calls.
    getter retry_buffer_size : Int64
    # The policy used when the service config does not select one.
    getter default_load_balancing_policy : String
    # The service config used when the resolver does not provide one.
    getter default_service_config : ServiceConfig?

    @parsed_target : Target
    @resolver_provider : Resolver::Provider
    @transport : TransportOptions
    @disable_service_config_lookup : Bool
    @legacy_port : Int32? = nil

    @mutex = Mutex.new
    @serializer = WorkSerializer.new
    # Notified whenever the state, picker or config changes.
    @changed = ::Channel(Nil).new
    @state = ConnectivityState::Idle
    @picker : LoadBalancer::Picker = LoadBalancer::QueuePicker.new
    @idle_mode = true
    @shutdown = false
    # Incremented whenever the resolver and policy are replaced; stale
    # callbacks are ignored.
    @generation = 0
    @resolver : Resolver? = nil
    @policy : LoadBalancer? = nil
    @policy_name : String? = nil
    @helper : Helper? = nil
    @subchannels = Set(Subchannel).new
    @service_config : ServiceConfig? = nil
    @config_ready = false
    @resolution_error : String? = nil
    @throttle : RetryThrottle? = nil
    @throttle_config : ServiceConfig::RetryThrottling? = nil
    @active_calls = 0
    @last_activity = Time.instant
    @retry_buffer_used = Atomic(Int64).new(0)
    @http2 : HTTP2::Client? = nil

    # Creates a channel to *target*.
    #
    # * *credentials*: transport security (default: plaintext, or TLS for
    #   `https://` targets). *tls* is a shortcut: `true` for TLS with the
    #   system roots, or an OpenSSL client context.
    # * *authority*: overrides the `:authority` sent with calls.
    # * *service_config*: the default service config (JSON or parsed); a
    #   config returned by the resolver takes precedence unless
    #   *disable_service_config_lookup* is set.
    # * *load_balancing_policy*: the policy used when the service config
    #   does not choose one.
    # * *resolver*: a resolver provider used instead of the registered one.
    # * *backoff*: connection backoff parameters.
    # * *idle_timeout*: release connections after this long without calls
    #   (`nil` to never go idle).
    # * *keepalive*: client keepalive settings for the HTTP/2 transport.
    # * *enable_retries*, *per_rpc_buffer_size*, *retry_buffer_size*:
    #   retry support (gRFC A6).
    # * *stats_handlers*: observers of every call (see `GRPC::Stats`).
    def initialize(target : String, *, tls : Bool | OpenSSL::SSL::Context::Client | Nil = nil,
                   credentials : ChannelCredentials? = nil,
                   authority : String? = nil, @user_agent : String = DEFAULT_USER_AGENT,
                   initial_window_size : UInt32 = 1_048_576_u32, connection_window_size : Int32 = 16_777_216,
                   max_header_list_size : UInt32 = 16_384_u32 * 1024,
                   service_config : String | ServiceConfig | Nil = nil, disable_service_config_lookup : Bool = false,
                   load_balancing_policy : String = "pick_first", resolver : Resolver::Provider? = nil,
                   @backoff : ConnectionBackoff = ConnectionBackoff.new, @idle_timeout : Time::Span? = DEFAULT_IDLE_TIMEOUT,
                   @keepalive : KeepaliveOptions? = nil, enable_retries : Bool = true,
                   @per_rpc_buffer_size : Int32 = DEFAULT_PER_RPC_BUFFER_SIZE,
                   retry_buffer_size : Int = DEFAULT_RETRY_BUFFER_SIZE,
                   stats_handlers : Array(StatsHandler) = [] of StatsHandler)
      @stats = Stats::Dispatcher.new(stats_handlers.dup)
      @target = target
      @retries_enabled = enable_retries
      @retry_buffer_size = retry_buffer_size.to_i64
      @disable_service_config_lookup = disable_service_config_lookup
      @default_load_balancing_policy = Channel.check_policy(load_balancing_policy)
      @default_service_config = Channel.to_service_config(service_config)

      parsed = Target.parse(target, ->(scheme : String) {
        scheme.in?("http", "https") || resolver.try(&.scheme.downcase) == scheme || Resolver.registered?(scheme)
      })
      legacy_authority = nil
      if parsed.scheme.in?("http", "https")
        # Legacy URL targets: resolved by DNS, the scheme selects TLS.
        tls = true if parsed.scheme == "https" && tls.nil? && credentials.nil?
        legacy_authority = parsed.authority
        host, port = Resolver.split_host_port(parsed.authority, parsed.scheme == "https" ? 443 : 80)
        @legacy_port = port
        endpoint = host.includes?(':') ? "[#{host}]:#{port}" : "#{host}:#{port}"
        parsed = Target.new("dns", "", endpoint, target, true)
      end
      @parsed_target = parsed
      @credentials = credentials || Channel.credentials_for(tls)
      @resolver_provider = resolver || Resolver.provider(parsed.scheme) ||
                           raise ArgumentError.new("No resolver for scheme #{parsed.scheme.inspect}")
      @resolver_provider.validate(parsed)
      @authority = authority || @credentials.server_name_override || legacy_authority ||
                   @resolver_provider.default_authority(parsed)

      settings = HTTP2::Settings.new(enable_push: false, initial_window_size: initial_window_size,
        max_header_list_size: max_header_list_size)
      @transport = TransportOptions.new(@credentials, @authority, settings, connection_window_size, @backoff, @keepalive)
      ChannelzRegistry.register(self)
    end

    # Creates a channel whose connections are created by *factory* (e.g.
    # an in-memory transport in tests). *target* is used as the authority.
    def initialize(@target : String, *, @user_agent : String = DEFAULT_USER_AGENT,
                   service_config : String | ServiceConfig | Nil = nil,
                   @backoff : ConnectionBackoff = ConnectionBackoff.new, @idle_timeout : Time::Span? = DEFAULT_IDLE_TIMEOUT,
                   enable_retries : Bool = true, @per_rpc_buffer_size : Int32 = DEFAULT_PER_RPC_BUFFER_SIZE,
                   retry_buffer_size : Int = DEFAULT_RETRY_BUFFER_SIZE,
                   stats_handlers : Array(StatsHandler) = [] of StatsHandler, &factory : -> IO)
      @stats = Stats::Dispatcher.new(stats_handlers.dup)
      @retries_enabled = enable_retries
      @retry_buffer_size = retry_buffer_size.to_i64
      @disable_service_config_lookup = false
      @default_load_balancing_policy = "pick_first"
      @default_service_config = Channel.to_service_config(service_config)
      @parsed_target = Target.new("custom", "", @target, @target, false)
      @credentials = ChannelCredentials.insecure
      @resolver_provider = CustomTransportProvider.new
      @authority = @target
      settings = HTTP2::Settings.new(enable_push: false, initial_window_size: 1_048_576_u32)
      @transport = TransportOptions.new(@credentials, @authority, settings, 16_777_216, @backoff, nil, factory)
      ChannelzRegistry.register(self)
    end

    # Identifier of the channel in channelz.
    getter channelz_id : Int64 = ChannelzRegistry.next_id
    # Call counters (channelz).
    getter call_metrics = CallMetrics.new
    # When the channel was created.
    getter created_at : Time = Time.utc

    # The channel's subchannels.
    def subchannels : Array(Subchannel)
      @mutex.synchronize { @subchannels.to_a }
    end

    # Stats handlers observing every call on this channel (see
    # `GRPC::Stats`).
    getter stats : Stats::Dispatcher

    # Adds a stats handler for calls started afterwards.
    def add_stats_handler(handler : StatsHandler) : self
      @stats.handlers << handler
      self
    end

    # `"https"` for secure channels, else `"http"`.
    def scheme : String
      secure? ? "https" : "http"
    end

    def secure? : Bool
      @credentials.secure?
    end

    # The parsed target.
    def parsed_target : Target
      @parsed_target
    end

    # The current connectivity state. With *try_to_connect* an IDLE channel
    # starts connecting.
    def state(try_to_connect : Bool = false) : ConnectivityState
      exit_idle if try_to_connect
      @mutex.synchronize { @state }
    end

    # Waits until the state differs from *source*, for at most *timeout*.
    # Returns `true` if it changed.
    def wait_for_state_change(source : ConnectivityState, timeout : Time::Span) : Bool
      deadline = Time.instant + timeout
      loop do
        changed = @mutex.synchronize do
          return true if @state != source
          @changed
        end
        remaining = deadline - Time.instant
        return false if remaining <= Time::Span.zero
        select
        when changed.receive?
        when timeout(remaining)
          return @mutex.synchronize { @state != source }
        end
      end
    end

    # Starts connecting if IDLE. With a *timeout*, waits until the channel
    # is READY and returns whether it became READY in time.
    def connect(timeout : Time::Span? = nil) : Bool
      state = self.state(try_to_connect: true)
      return state.ready? unless timeout
      deadline = Time.instant + timeout
      until state.ready?
        return false if state.shutdown?
        remaining = deadline - Time.instant
        return false if remaining <= Time::Span.zero
        wait_for_state_change(state, remaining)
        state = self.state(try_to_connect: true)
      end
      true
    end

    # Releases all connections and returns to IDLE: calls in flight may
    # finish within *grace*, new calls reconnect.
    def close(grace : Time::Span = 1.second) : Nil
      enter_idle(force: true)
      @transport.close_all(grace)
      @http2.try &.close
    end

    # Closes the channel for good: the state becomes SHUTDOWN and new calls
    # fail with `UNAVAILABLE`.
    def shutdown(grace : Time::Span = 1.second) : Nil
      @mutex.synchronize { @shutdown = true }
      enter_idle(force: true)
      set_state(ConnectivityState::Shutdown, LoadBalancer::FailPicker.new(Status.new(StatusCode::Unavailable, "Channel shut down")))
      @transport.close_all(grace)
      @http2.try &.close
    end

    def shutdown? : Bool
      @mutex.synchronize { @shutdown }
    end

    # Makes subchannels waiting for their connection backoff retry
    # immediately (e.g. after the network came back).
    def reset_connect_backoff : Nil
      subchannels = @mutex.synchronize { @subchannels.to_a }
      subchannels.each &.reset_backoff
    end

    # The service config in effect (after name resolution).
    def service_config : ServiceConfig?
      @mutex.synchronize { @service_config }
    end

    # The name of the load balancing policy in use.
    def load_balancing_policy : String?
      @mutex.synchronize { @policy_name }
    end

    # A plain HTTP/2 client for the target's first address. Not used for
    # calls; kept for compatibility.
    def http2 : HTTP2::Client
      @mutex.synchronize do
        @http2 ||= begin
          if factory = @transport.io_factory
            HTTP2::Client.new(@authority, &factory)
          else
            host, port = Resolver.split_host_port(@parsed_target.endpoint)
            HTTP2::Client.new(host, @legacy_port || port, @credentials.tls_context || false)
          end
        end
      end
    end

    # :nodoc:
    def self.parse_host_port(address : String, default_port : Int32) : {String, Int32}
      if address.starts_with?('[')
        host, _, rest = address.lchop('[').partition(']')
        port = rest.lchop(':')
        {host, port.empty? ? default_port : port.to_i}
      elsif address.count(':') == 1
        host, _, port = address.partition(':')
        {host, port.to_i}
      else
        {address, default_port}
      end
    end

    # --- Calls ---

    # :nodoc:
    #
    # Waits for the first name resolution and returns the service config
    # (nil without one). Fails with UNAVAILABLE if resolution failed, unless
    # *wait_for_ready*.
    def await_service_config(wait_for_ready : Bool, deadline : Time::Instant?, cancelled : ::Channel(Nil)) : ServiceConfig?
      loop do
        exit_idle
        changed = @mutex.synchronize do
          raise Error.new(StatusCode::Unavailable, "Channel shut down") if @shutdown
          return @service_config if @config_ready
          if (error = @resolution_error) && !wait_for_ready
            raise Error.new(StatusCode::Unavailable, error)
          end
          @changed
        end
        wait_for_change(changed, deadline, cancelled)
      end
    end

    # :nodoc:
    #
    # Picks a READY connection for a call attempt, waiting while the
    # channel connects (or, for wait-for-ready calls, while it fails).
    def pick_connection(info : LoadBalancer::PickInfo, wait_for_ready : Bool, deadline : Time::Instant?,
                        cancelled : ::Channel(Nil)) : HTTP2::Connection
      loop do
        exit_idle
        picker, changed = @mutex.synchronize do
          raise PickError.new(Status.new(StatusCode::Unavailable, "Channel shut down"), drop: true) if @shutdown
          {@picker, @changed}
        end
        result = picker.pick(info)
        case result.kind
        in .complete?
          if connection = result.subchannel.try(&.ready_connection)
            return connection
          end
        in .queue?
        in .fail?
          raise PickError.new(result.status.not_nil!, drop: false) unless wait_for_ready
        in .drop?
          raise PickError.new(result.status.not_nil!, drop: true)
        end
        wait_for_change(changed, deadline, cancelled)
      end
    end

    # :nodoc:
    def call_started : Nil
      @mutex.synchronize do
        @active_calls += 1
        @last_activity = Time.instant
      end
    end

    # :nodoc:
    def call_finished : Nil
      @mutex.synchronize do
        @active_calls -= 1
        @last_activity = Time.instant
      end
    end

    # :nodoc:
    def retry_throttle : RetryThrottle?
      @mutex.synchronize { @throttle }
    end

    # :nodoc:
    #
    # Reserves *bytes* of the channel's retry buffer. Returns `false` if the
    # limit would be exceeded.
    def reserve_retry_buffer(bytes : Int) : Bool
      used = @retry_buffer_used.add(bytes.to_i64) + bytes
      return true if used <= @retry_buffer_size
      @retry_buffer_used.sub(bytes.to_i64)
      false
    end

    # :nodoc:
    def force_reserve_retry_buffer(bytes : Int) : Nil
      @retry_buffer_used.add(bytes.to_i64)
    end

    # :nodoc:
    def release_retry_buffer(bytes : Int) : Nil
      @retry_buffer_used.sub(bytes.to_i64) if bytes > 0
    end

    # :nodoc:
    def retry_buffer_used : Int64
      @retry_buffer_used.get
    end

    private def wait_for_change(changed : ::Channel(Nil), deadline : Time::Instant?, cancelled : ::Channel(Nil)) : Nil
      if deadline
        remaining = deadline - Time.instant
        raise Error.new(StatusCode::DeadlineExceeded, "Deadline exceeded while waiting for a connection") if remaining <= Time::Span.zero
        select
        when changed.receive?
        when cancelled.receive?
          raise Error.new(StatusCode::Cancelled, "Call cancelled")
        when timeout(remaining)
          raise Error.new(StatusCode::DeadlineExceeded, "Deadline exceeded while waiting for a connection")
        end
      else
        select
        when changed.receive?
        when cancelled.receive?
          raise Error.new(StatusCode::Cancelled, "Call cancelled")
        end
      end
    end

    # --- Idle mode, resolution and load balancing ---

    # Leaves idle mode (starts resolving), or asks an IDLE policy to
    # connect.
    private def exit_idle : Nil
      resolver = nil
      generation = 0
      policy_idle = false
      @mutex.synchronize do
        return if @shutdown
        if @idle_mode
          @idle_mode = false
          @generation += 1
          generation = @generation
          @last_activity = Time.instant
          resolver = @resolver = @resolver_provider.build(@parsed_target, ->(result : Resolver::Result) {
            on_resolver_result(generation, result)
            nil
          })
        elsif @state.idle?
          policy_idle = true
        else
          return
        end
      end
      if resolver
        set_state(ConnectivityState::Connecting, LoadBalancer::QueuePicker.new, generation)
        start_idle_timer(generation)
        resolver.start
      elsif policy_idle
        @serializer.run { @policy.try &.exit_idle }
      end
    end

    # Shuts the resolver and policy down and returns to IDLE. Without
    # *force* only if the channel had no calls for `idle_timeout`.
    private def enter_idle(force : Bool) : Nil
      resolver = nil
      generation = @mutex.synchronize do
        return if @idle_mode
        return unless force || (@active_calls == 0 && idle_expired?)
        @idle_mode = true
        @generation += 1
        resolver = @resolver
        @resolver = nil
        @generation
      end
      resolver.try &.shutdown
      @serializer.run do
        # A newer policy may already exist if the channel left idle mode
        # again meanwhile.
        if (helper = @helper) && helper.generation < generation
          @policy.try &.shutdown
          @policy = nil
          @helper = nil
          @mutex.synchronize { @policy_name = nil }
        end
      end
      set_state(ConnectivityState::Idle, LoadBalancer::QueuePicker.new, generation)
    end

    private def idle_expired? : Bool
      timeout = @idle_timeout
      !timeout.nil? && Time.instant - @last_activity >= timeout
    end

    # Enters idle mode once there were no calls for `idle_timeout`.
    private def start_idle_timer(generation : Int32) : Nil
      return unless timeout = @idle_timeout
      spawn(name: "grpc-channel-idle") do
        loop do
          wait = @mutex.synchronize do
            if @generation != generation || @idle_mode
              nil
            elsif @active_calls > 0
              timeout
            else
              @last_activity + timeout - Time.instant
            end
          end
          break unless wait
          if wait <= Time::Span.zero
            enter_idle(force: false)
          else
            sleep wait
          end
        end
      end
    end

    private def on_resolver_result(generation : Int32, result : Resolver::Result) : Nil
      @serializer.run do
        next unless @mutex.synchronize { @generation == generation && !@shutdown }
        handle_resolution(generation, result)
      end
    end

    # Runs in the serializer.
    private def handle_resolution(generation : Int32, result : Resolver::Result) : Nil
      if result.error? || result.addresses.empty?
        resolution_failed(generation, result.error || "Name resolution returned no addresses")
        return
      end

      config = select_service_config(result)
      if config.is_a?(String)
        resolution_failed(generation, config)
        return
      end

      name = config.try(&.load_balancing_policy) || @default_load_balancing_policy
      lb_config = config.try(&.load_balancing_config) || JSON::Any.new({} of String => JSON::Any)
      provider = LoadBalancer.provider(name) || raise "Unknown load balancing policy #{name}"

      @mutex.synchronize do
        @service_config = config
        @config_ready = true
        @resolution_error = nil
        update_throttle_locked(config.try(&.retry_throttling))
      end
      notify_change

      policy = @policy
      if policy.nil? || @mutex.synchronize { @policy_name } != name
        policy.try &.shutdown
        helper = Helper.new(self, generation)
        @helper = helper
        policy = @policy = provider.build(helper)
        @mutex.synchronize { @policy_name = name }
      end
      policy.update(result.addresses, lb_config)
    end

    # Returns the config to use, or an error message.
    private def select_service_config(result : Resolver::Result) : ServiceConfig | String | Nil
      json = result.service_config
      return @default_service_config if json.nil? || @disable_service_config_lookup
      ServiceConfig.parse(json)
    rescue e : ServiceConfig::Error
      # Keep the previous valid config, if any.
      previous = @mutex.synchronize { @service_config if @config_ready }
      previous || "Invalid service config from resolver: #{e.message}"
    end

    private def resolution_failed(generation : Int32, message : String) : Nil
      if policy = @policy
        policy.resolver_error(message)
      else
        @mutex.synchronize { @resolution_error = message }
        set_state(ConnectivityState::TransientFailure,
          LoadBalancer::FailPicker.new(Status.new(StatusCode::Unavailable, message)), generation)
      end
    end

    private def update_throttle_locked(config : ServiceConfig::RetryThrottling?) : Nil
      return if config == @throttle_config
      @throttle_config = config
      @throttle = config.try { |c| RetryThrottle.new(c.max_tokens, c.token_ratio) }
    end

    protected def set_state(state : ConnectivityState, picker : LoadBalancer::Picker, generation : Int32? = nil) : Nil
      changed = @mutex.synchronize do
        return if generation && generation != @generation
        return if @shutdown && !state.shutdown?
        @state = state
        @picker = picker
        previous = @changed
        @changed = ::Channel(Nil).new
        previous
      end
      changed.close
    end

    private def notify_change : Nil
      changed = @mutex.synchronize do
        previous = @changed
        @changed = ::Channel(Nil).new
        previous
      end
      changed.close
    end

    protected def create_subchannel(address : Resolver::Address) : Subchannel
      subchannel = Subchannel.new(address, @transport, @serializer)
      subchannel.watch do |state|
        @mutex.synchronize { @subchannels.delete(subchannel) } if state.shutdown?
      end
      @mutex.synchronize { @subchannels << subchannel }
      subchannel
    end

    protected def request_reresolution(generation : Int32) : Nil
      resolver = @mutex.synchronize { @resolver if @generation == generation }
      resolve_later(resolver) if resolver
    end

    # Calls `Resolver#resolve_now` outside the serializer: resolvers may
    # deliver results synchronously.
    private def resolve_later(resolver : Resolver) : Nil
      spawn(name: "grpc-resolve-now") { resolver.resolve_now }
    end

    protected def serializer : WorkSerializer
      @serializer
    end

    protected def current_helper?(helper : Helper) : Bool
      @helper.same?(helper)
    end

    # The `LoadBalancer::Helper` given to policies. Updates from replaced
    # policies are ignored.
    private class Helper < LoadBalancer::Helper
      getter generation : Int32

      def initialize(@channel : Channel, @generation : Int32)
      end

      def create_subchannel(address : Resolver::Address) : Subchannel
        @channel.create_subchannel(address)
      end

      def update_state(state : ConnectivityState, picker : LoadBalancer::Picker) : Nil
        return unless @channel.current_helper?(self)
        @channel.set_state(state, picker, @generation)
      end

      def request_reresolution : Nil
        @channel.request_reresolution(@generation)
      end

      def schedule(&block : ->) : Nil
        @channel.serializer.run(&block)
      end

      def authority : String
        @channel.authority
      end
    end

    # Resolves channels with a custom IO factory to a single address.
    private class CustomTransportProvider < Resolver::Provider
      def scheme : String
        "custom"
      end

      def build(target : Target, listener : Resolver::Listener) : Resolver
        address = Resolver::Address.new(Resolver::Address::Kind::Custom, path: target.endpoint)
        StaticResolver.new(Resolver::Result.new([address]), listener)
      end
    end

    # :nodoc:
    def self.credentials_for(tls : Bool | OpenSSL::SSL::Context::Client | Nil) : ChannelCredentials
      case tls
      in OpenSSL::SSL::Context::Client then ChannelCredentials.tls(tls)
      in true                          then ChannelCredentials.tls
      in false, nil                    then ChannelCredentials.insecure
      end
    end

    # :nodoc:
    def self.to_service_config(config : String | ServiceConfig | Nil) : ServiceConfig?
      case config
      in String        then ServiceConfig.parse(config)
      in ServiceConfig then config
      in Nil           then nil
      end
    end

    # :nodoc:
    def self.check_policy(name : String) : String
      LoadBalancer.provider(name) || raise ArgumentError.new("Unknown load balancing policy #{name.inspect}")
      name
    end
  end

  # :nodoc:
  #
  # Raised when the load balancing policy fails a call. Dropped calls must
  # not be retried.
  class PickError < Error
    getter? drop : Bool

    def initialize(status : Status, *, @drop : Bool)
      super(status)
    end
  end

  # :nodoc:
  #
  # The retry throttling token bucket of a channel (gRFC A6). Tokens are
  # kept in thousandths to apply `token_ratio` exactly.
  class RetryThrottle
    getter max_tokens : Int32
    getter token_ratio : Float64

    def initialize(@max_tokens : Int32, @token_ratio : Float64)
      @tokens = @max_tokens * 1000
      @ratio = (@token_ratio * 1000).round.to_i32
      @mutex = Mutex.new
    end

    # Records a failed attempt (retryable or non-fatal status, or pushback
    # forbidding retries).
    def record_failure : Nil
      @mutex.synchronize { @tokens = Math.max(@tokens - 1000, 0) }
    end

    def record_success : Nil
      @mutex.synchronize { @tokens = Math.min(@tokens + @ratio, @max_tokens * 1000) }
    end

    # Whether retries and hedges are currently allowed.
    def allows_retry? : Bool
      @mutex.synchronize { @tokens > @max_tokens * 500 }
    end

    def tokens : Float64
      @mutex.synchronize { @tokens / 1000.0 }
    end
  end
end
