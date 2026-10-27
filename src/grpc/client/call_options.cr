module GRPC
  # Per-call settings. `nil` fields fall back to the client's defaults (and
  # then to the service config).
  #
  # ```
  # options = GRPC::CallOptions.new(wait_for_ready: true, timeout: 5.seconds,
  #   call_credentials: GRPC::CallCredentials.bearer(token))
  # client.with_options(options).say_hello(request)
  # client.call_unary("/helloworld.Greeter/SayHello", request, Helloworld::HelloReply, options: options)
  # ```
  struct CallOptions
    # Queue the call while the channel is connecting or failing instead of
    # failing fast with `UNAVAILABLE` (see
    # https://github.com/grpc/grpc/blob/master/doc/wait-for-ready.md).
    getter wait_for_ready : Bool?
    # Credentials adding metadata to the call (in addition to the channel's).
    getter call_credentials : CallCredentials?
    # Compression of request messages (`"identity"` for none).
    getter compression : String?
    getter max_receive_message_size : Int32?
    getter max_send_message_size : Int32?
    # Deadline relative to the start of the call, for calls without one.
    getter timeout : Time::Span?
    # Metadata added to the call.
    getter metadata : Metadata?

    def initialize(*, @wait_for_ready : Bool? = nil, @call_credentials : CallCredentials? = nil,
                   @compression : String? = nil, @max_receive_message_size : Int32? = nil,
                   @max_send_message_size : Int32? = nil, @timeout : Time::Span? = nil,
                   metadata : Metadata | Hash(String, String) | Nil = nil)
      @metadata = metadata.is_a?(Hash) ? Metadata.new(metadata) : metadata
      if (encoding = @compression) && !Compression.supported?(encoding)
        raise ArgumentError.new("Unsupported compression #{encoding}")
      end
    end

    # Returns options where the non-nil settings of *other* override these.
    # Call credentials are composed and metadata is concatenated.
    def merge(other : CallOptions) : CallOptions
      credentials = case {mine = @call_credentials, theirs = other.call_credentials}
                    when {CallCredentials, CallCredentials} then mine.not_nil!.compose(theirs.not_nil!)
                    else                                         theirs || mine
                    end
      metadata = if (mine_md = @metadata) && (theirs_md = other.metadata)
                   mine_md.dup.merge!(theirs_md)
                 else
                   other.metadata || @metadata
                 end
      CallOptions.new(
        wait_for_ready: other.wait_for_ready.nil? ? @wait_for_ready : other.wait_for_ready,
        call_credentials: credentials,
        compression: other.compression || @compression,
        max_receive_message_size: other.max_receive_message_size || @max_receive_message_size,
        max_send_message_size: other.max_send_message_size || @max_send_message_size,
        timeout: other.timeout || @timeout,
        metadata: metadata)
    end
  end
end
