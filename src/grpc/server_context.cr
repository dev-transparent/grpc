module GRPC
  # Per-call context passed to service methods.
  #
  # It exposes the request metadata and deadline, lets the handler set
  # response metadata (sent as headers) and trailers, and reports
  # cancellation.
  class ServerContext
    # The full method path, e.g. `/helloworld.Greeter/SayHello`.
    getter method_path : String
    # Metadata sent by the client.
    getter metadata : Metadata
    # Metadata sent to the client in the response headers. Must be set before
    # the first response message is sent (or `#send_response_metadata`).
    getter response_metadata = Metadata.new
    # Metadata sent to the client in the trailers.
    getter trailers = Metadata.new
    # The `:authority` of the request.
    getter authority : String?
    # The address of the client, if known.
    getter peer : String?
    # Compression algorithm used for response messages (`nil` for none).
    # Only algorithms the client accepts are used.
    property compression : String?
    # Whether the most recently received request message was compressed.
    getter? request_compressed : Bool = false

    @deadline : Time::Instant?
    @cancelled : StatusCode? = nil
    @cancel_callbacks = [] of Proc(Nil)
    @mutex = Mutex.new
    @call : ServerCall? = nil

    def initialize(@method_path : String, @metadata : Metadata = Metadata.new, timeout : Time::Span? = nil,
                   @authority : String? = nil, @peer : String? = nil, @compression : String? = nil)
      @deadline = timeout.try { |t| Time.instant + t }
    end

    # The service part of the method path, e.g. `helloworld.Greeter`.
    def service_name : String
      @method_path.lchop('/').split('/', 2)[0]
    end

    # The method part of the method path, e.g. `SayHello`.
    def method_name : String
      @method_path.split('/').last
    end

    # The time left until the call's deadline, or `nil` without a deadline.
    def time_remaining : Time::Span?
      @deadline.try { |deadline| deadline - Time.instant }
    end

    # Returns `true` if the client set a deadline that has passed.
    def deadline_exceeded? : Bool
      remaining = time_remaining
      !remaining.nil? && remaining <= Time::Span.zero
    end

    # Returns `true` if the call was cancelled by the client, timed out, or
    # the connection was lost.
    def cancelled? : Bool
      @mutex.synchronize { !@cancelled.nil? }
    end

    # The reason the call was cancelled (`Cancelled` or `DeadlineExceeded`).
    def cancellation_code : StatusCode?
      @mutex.synchronize { @cancelled }
    end

    # Registers a block called when the call is cancelled. Called immediately
    # if the call is already cancelled.
    def on_cancel(&block : -> Nil) : Nil
      run_now = @mutex.synchronize do
        if @cancelled
          true
        else
          @cancel_callbacks << block
          false
        end
      end
      block.call if run_now
    end

    # Raises `GRPC::Error` if the call was cancelled. Long running handlers
    # can call this periodically to stop early.
    def check_cancelled! : Nil
      if code = cancellation_code
        raise Error.new(code, code.deadline_exceeded? ? "Deadline exceeded" : "Call cancelled")
      end
    end

    # Sends the response metadata immediately, before any message.
    def send_response_metadata : Nil
      @call.try &.send_headers
    end

    protected def request_compressed=(@request_compressed : Bool)
    end

    protected def call=(call : ServerCall) : ServerCall
      @call = call
    end

    protected def cancel(code : StatusCode) : Nil
      callbacks = @mutex.synchronize do
        return if @cancelled
        @cancelled = code
        list = @cancel_callbacks
        @cancel_callbacks = [] of Proc(Nil)
        list
      end
      callbacks.each do |callback|
        callback.call
      rescue e
        Log.warn(exception: e) { "Exception in on_cancel callback" }
      end
    end
  end
end
