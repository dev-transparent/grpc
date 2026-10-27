require "./client/connectivity"
require "./client/backoff"
require "./client/keepalive"
require "./client/target"
require "./client/resolver"
require "./client/dns_resolver"
require "./client/credentials"
require "./client/load_balancer"
require "./client/pick_first"
require "./client/round_robin"
require "./client/service_config"
require "./client/subchannel"
require "./client/channel"
require "./client/call_options"

module GRPC
  # Information about a call being started, passed to client interceptors.
  # Interceptors may modify the metadata, deadline and per-call settings.
  class CallInfo
    getter method_path : String
    property metadata : Metadata
    # The call's deadline, if any.
    property deadline : Time::Instant?
    # Whether the call waits for the channel to become READY (`nil` to
    # use the service config's setting).
    property wait_for_ready : Bool?
    # Call credentials of the call (in addition to the channel's).
    property call_credentials : CallCredentials?
    # Compression of request messages (`nil` for none).
    property compression : String?

    def initialize(@method_path : String, @metadata : Metadata, @deadline : Time::Instant?, *,
                   @wait_for_ready : Bool? = nil, @call_credentials : CallCredentials? = nil,
                   @compression : String? = nil)
    end

    # Sets the deadline relative to now.
    def timeout=(span : Time::Span) : Nil
      @deadline = Time.instant + span
    end
  end

  # Intercepts calls started by a client, e.g. to add metadata, log or
  # reject calls. Call `continuation.call` to start the call.
  #
  # ```
  # class TokenInterceptor < GRPC::ClientInterceptor
  #   def call(info : GRPC::CallInfo, continuation : -> GRPC::ClientCall) : GRPC::ClientCall
  #     info.metadata["authorization"] = "Bearer #{token}"
  #     continuation.call
  #   end
  # end
  # ```
  abstract class ClientInterceptor
    abstract def call(info : CallInfo, continuation : -> ClientCall) : ClientCall

    # :nodoc:
    class ProcInterceptor < ClientInterceptor
      def initialize(@proc : Proc(CallInfo, Proc(ClientCall), ClientCall))
      end

      def call(info : CallInfo, continuation : -> ClientCall) : ClientCall
        @proc.call(info, continuation)
      end
    end
  end

  # Base class of generated client stubs.
  #
  # Settings given to the constructor (or changed with the properties)
  # apply to every call; `#with_options` returns a copy of the stub with
  # different defaults, and the `call_*` helpers accept per-call
  # `CallOptions`:
  #
  # ```
  # client = Helloworld::Greeter::Client.new(channel, default_timeout: 5.seconds,
  #   call_credentials: GRPC::CallCredentials.bearer(token))
  # client.with_options(wait_for_ready: true).say_hello(request)
  # ```
  class Client
    getter channel : Channel
    # Metadata sent with every call.
    getter metadata : Metadata
    # Deadline applied to calls that do not specify one.
    property default_timeout : Time::Span?
    # Compression used for request messages (`nil` for none).
    property compression : String?
    property max_receive_message_size : Int32
    property max_send_message_size : Int32
    # Whether calls wait for the channel to become READY instead of failing
    # fast (`nil`: as configured by the service config, else fail fast).
    property wait_for_ready : Bool?
    # Credentials adding metadata to every call.
    property call_credentials : CallCredentials?

    @interceptors = [] of ClientInterceptor

    def initialize(@channel : Channel, *, metadata : Metadata | Hash(String, String) | Nil = nil,
                   @default_timeout : Time::Span? = nil, @compression : String? = nil,
                   @max_receive_message_size : Int32 = DEFAULT_MAX_RECEIVE_MESSAGE_SIZE,
                   @max_send_message_size : Int32 = DEFAULT_MAX_SEND_MESSAGE_SIZE,
                   interceptors : Array(ClientInterceptor) = [] of ClientInterceptor,
                   @wait_for_ready : Bool? = nil, @call_credentials : CallCredentials? = nil)
      @metadata = Client.to_metadata(metadata)
      @interceptors.concat(interceptors)
      if (encoding = @compression) && !Compression.supported?(encoding)
        raise ArgumentError.new("Unsupported compression #{encoding}")
      end
    end

    # Creates a client with a new channel to *target* (see `Channel`).
    def self.new(target : String, *, tls : Bool | OpenSSL::SSL::Context::Client | Nil = nil,
                 credentials : ChannelCredentials? = nil, service_config : String | ServiceConfig | Nil = nil,
                 metadata : Metadata | Hash(String, String) | Nil = nil, default_timeout : Time::Span? = nil,
                 compression : String? = nil,
                 max_receive_message_size : Int32 = DEFAULT_MAX_RECEIVE_MESSAGE_SIZE,
                 max_send_message_size : Int32 = DEFAULT_MAX_SEND_MESSAGE_SIZE,
                 interceptors : Array(ClientInterceptor) = [] of ClientInterceptor,
                 wait_for_ready : Bool? = nil, call_credentials : CallCredentials? = nil)
      channel = Channel.new(target, tls: tls, credentials: credentials, service_config: service_config)
      new(channel, metadata: metadata, default_timeout: default_timeout, compression: compression,
        max_receive_message_size: max_receive_message_size, max_send_message_size: max_send_message_size,
        interceptors: interceptors, wait_for_ready: wait_for_ready, call_credentials: call_credentials)
    end

    # Returns a copy of this client (sharing the channel) whose calls use
    # *options* on top of this client's settings.
    def with_options(options : CallOptions) : self
      copy = dup
      copy.apply_defaults(options)
      copy
    end

    # :ditto:
    def with_options(*, wait_for_ready : Bool? = nil, call_credentials : CallCredentials? = nil,
                     compression : String? = nil, max_receive_message_size : Int32? = nil,
                     max_send_message_size : Int32? = nil, timeout : Time::Span? = nil,
                     metadata : Metadata | Hash(String, String) | Nil = nil) : self
      with_options(CallOptions.new(wait_for_ready: wait_for_ready, call_credentials: call_credentials,
        compression: compression, max_receive_message_size: max_receive_message_size,
        max_send_message_size: max_send_message_size, timeout: timeout, metadata: metadata))
    end

    protected def apply_defaults(options : CallOptions) : Nil
      @interceptors = @interceptors.dup
      @metadata = @metadata.dup.merge!(options.metadata || Metadata.new)
      @wait_for_ready = options.wait_for_ready unless options.wait_for_ready.nil?
      if credentials = options.call_credentials
        @call_credentials = (existing = @call_credentials) ? existing.compose(credentials) : credentials
      end
      @compression = options.compression if options.compression
      options.max_receive_message_size.try { |size| @max_receive_message_size = size }
      options.max_send_message_size.try { |size| @max_send_message_size = size }
      options.timeout.try { |timeout| @default_timeout = timeout }
    end

    # Adds an interceptor.
    def intercept(interceptor : ClientInterceptor) : self
      @interceptors << interceptor
      self
    end

    # Adds an interceptor given as a block.
    def intercept(&block : CallInfo, Proc(ClientCall) -> ClientCall) : self
      intercept(ClientInterceptor::ProcInterceptor.new(block))
    end

    # Closes the channel's connections (see `Channel#close`).
    def close : Nil
      @channel.close
    end

    # Starts a call. Used by the typed call helpers below.
    def start_call(method_path : String, metadata : Metadata | Hash(String, String) | Nil = nil,
                   deadline : Time::Span | Time | Nil = nil, options : CallOptions? = nil) : ClientCall
      call_metadata = @metadata.dup.merge!(Client.to_metadata(metadata))
      if extra = options.try(&.metadata)
        call_metadata.merge!(extra)
      end
      wait_for_ready = options.try(&.wait_for_ready)
      wait_for_ready = @wait_for_ready if wait_for_ready.nil?
      credentials = @call_credentials
      if (call_credentials = options.try(&.call_credentials))
        credentials = credentials ? credentials.compose(call_credentials) : call_credentials
      end
      timeout = options.try(&.timeout) || @default_timeout
      info = CallInfo.new(method_path, call_metadata, monotonic_deadline(deadline, timeout),
        wait_for_ready: wait_for_ready, call_credentials: credentials,
        compression: options.try(&.compression) || @compression)
      run_interceptors(info, 0, options)
    end

    # Performs a unary call and returns the response message.
    def call_unary(method_path : String, request : Protobuf::Message, response_type : Resp.class,
                   metadata : Metadata | Hash(String, String) | Nil = nil, deadline : Time::Span | Time | Nil = nil,
                   options : CallOptions? = nil) : Resp forall Resp
      start_unary(method_path, request, Resp, metadata, deadline, options).response
    end

    # Starts a unary call, returning a `UnaryCall` that also exposes the
    # response metadata.
    def start_unary(method_path : String, request : Protobuf::Message, response_type : Resp.class,
                    metadata : Metadata | Hash(String, String) | Nil = nil, deadline : Time::Span | Time | Nil = nil,
                    options : CallOptions? = nil) : UnaryCall(Resp) forall Resp
      call = start_call(method_path, metadata, deadline, options)
      call.send_message(request, end_stream: true)
      UnaryCall(Resp).new(call)
    end

    # Starts a server streaming call.
    def call_server_streaming(method_path : String, request : Protobuf::Message, response_type : Resp.class,
                              metadata : Metadata | Hash(String, String) | Nil = nil,
                              deadline : Time::Span | Time | Nil = nil,
                              options : CallOptions? = nil) : ServerStreamingCall(Resp) forall Resp
      call = start_call(method_path, metadata, deadline, options)
      call.send_message(request, end_stream: true)
      ServerStreamingCall(Resp).new(call)
    end

    # Starts a client streaming call.
    def call_client_streaming(method_path : String, request_type : Req.class, response_type : Resp.class,
                              metadata : Metadata | Hash(String, String) | Nil = nil,
                              deadline : Time::Span | Time | Nil = nil,
                              options : CallOptions? = nil) : ClientStreamingCall(Req, Resp) forall Req, Resp
      ClientStreamingCall(Req, Resp).new(start_call(method_path, metadata, deadline, options))
    end

    # Starts a bidirectional streaming call.
    def call_bidi_streaming(method_path : String, request_type : Req.class, response_type : Resp.class,
                            metadata : Metadata | Hash(String, String) | Nil = nil,
                            deadline : Time::Span | Time | Nil = nil,
                            options : CallOptions? = nil) : BidiStreamingCall(Req, Resp) forall Req, Resp
      BidiStreamingCall(Req, Resp).new(start_call(method_path, metadata, deadline, options))
    end

    private def run_interceptors(info : CallInfo, index : Int32, options : CallOptions?) : ClientCall
      if interceptor = @interceptors[index]?
        interceptor.call(info, -> { run_interceptors(info, index + 1, options) })
      else
        settings = ClientCall::Settings.new(
          compression: info.compression,
          max_receive_message_size: options.try(&.max_receive_message_size) || @max_receive_message_size,
          max_send_message_size: options.try(&.max_send_message_size) || @max_send_message_size,
          wait_for_ready: info.wait_for_ready,
          call_credentials: info.call_credentials)
        ClientCall.start(@channel, info.method_path, info.metadata, info.deadline, settings)
      end
    end

    private def monotonic_deadline(deadline : Time::Span | Time | Nil, timeout : Time::Span?) : Time::Instant?
      case deadline
      when Time::Span then Time.instant + deadline
      when Time       then Time.instant + (deadline - Time.utc)
      else                 timeout.try { |span| Time.instant + span }
      end
    end

    # :nodoc:
    def self.to_metadata(metadata : Metadata | Hash(String, String) | Nil) : Metadata
      case metadata
      when Metadata then metadata
      when Hash     then Metadata.new(metadata)
      else               Metadata.new
      end
    end
  end
end
