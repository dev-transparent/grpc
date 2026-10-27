module HTTP2
  # A single HTTP/2 stream. Streams are created by a `Connection`; all state is
  # protected by the connection's mutex.
  #
  # The receiving side exposes the peer's header block (`#headers`), body
  # (`#read` / `#body`) and trailers (`#trailers`). The sending side writes
  # with `#send_headers`, `#send_data` and `#send_trailers`, all of which
  # respect flow control and block when the peer's window is exhausted.
  class Stream
    enum State
      Idle
      Open
      HalfClosedLocal
      HalfClosedRemote
      Closed
    end

    getter id : UInt32
    getter connection : Connection
    getter state : State = State::Idle

    protected property send_window : Int64
    protected property recv_window : Int64
    protected property pending_recv_credit : Int64 = 0
    protected property content_length : Int64? = nil
    protected property data_received : Int64 = 0
    protected getter cond = Condition.new
    protected property? head_request : Bool = false

    @received_headers : Array({String, String})? = nil
    @received_trailers : Array({String, String})? = nil
    @data = Deque(Bytes).new
    @data_offset = 0
    @end_stream_received = false
    @end_stream_sent = false
    @headers_sent = false
    @error : Exception? = nil
    @close_callbacks = [] of Proc(Stream, Nil)
    @body : Body? = nil

    def initialize(@connection : Connection, @id : UInt32, @send_window : Int64, @recv_window : Int64)
    end

    # Returns `true` if the stream was initiated by the local endpoint.
    def local? : Bool
      @connection.client? ? @id.odd? : @id.even?
    end

    # Waits for and returns the peer's (final) header block, including
    # pseudo-header fields. Raises if the stream is reset before headers
    # arrive.
    def headers : Array({String, String})
      @connection.synchronize do
        loop do
          if headers = @received_headers
            return headers
          end
          raise_error!
          raise ConnectionClosedError.new("Stream closed before headers were received") if @state.closed?
          @cond.wait(@connection.mutex)
        end
      end
    end

    # Returns the peer's header block if it was received already.
    def headers? : Array({String, String})?
      @connection.synchronize { @received_headers }
    end

    # Returns the trailers sent by the peer. Only available after the body
    # was read completely.
    def trailers : Array({String, String})?
      @connection.synchronize { @received_trailers }
    end

    # An `IO` reading the peer's message body.
    def body : Body
      @connection.synchronize { @body ||= Body.new(self) }
    end

    # Reads body data into *slice*. Returns 0 at end of stream. Raises
    # `StreamResetError` if the stream was reset before the body was complete.
    def read(slice : Bytes) : Int32
      return 0 if slice.empty?
      @connection.synchronize do
        loop do
          if chunk = @data.first?
            available = chunk.size - @data_offset
            count = Math.min(available, slice.size)
            slice.copy_from(chunk.to_unsafe + @data_offset, count)
            if count == available
              @data.shift
              @data_offset = 0
            else
              @data_offset += count
            end
            @connection.consumed_data(self, count)
            return count
          end
          return 0 if @end_stream_received
          raise_error!
          return 0 if @state.closed?
          @cond.wait(@connection.mutex)
        end
      end
    end

    # Waits until the peer finished sending (END_STREAM) or the stream closed.
    # Returns the trailers if any.
    def wait_end_stream : Array({String, String})?
      @connection.synchronize do
        until @end_stream_received || @state.closed?
          @cond.wait(@connection.mutex)
        end
        @received_trailers
      end
    end

    # Sends a header block. Pass `end_stream: true` to close the sending side.
    def send_headers(headers : Array({String, String}), end_stream : Bool = false) : Nil
      @connection.send_headers(self, headers, end_stream)
    end

    # Sends body data, blocking while flow control windows are exhausted.
    def send_data(data : Bytes, end_stream : Bool = false) : Nil
      @connection.send_data(self, data, end_stream)
    end

    # Sends trailers and closes the sending side.
    def send_trailers(trailers : Array({String, String})) : Nil
      send_headers(trailers, end_stream: true)
    end

    # Closes the sending side of the stream with an empty DATA frame if it is
    # still open.
    def close_send : Nil
      return if end_stream_sent?
      send_data(Bytes.empty, end_stream: true)
    end

    # Resets the stream with *code*.
    def reset(code : ErrorCode = ErrorCode::CANCEL) : Nil
      @connection.reset_stream(self, code)
    end

    # Blocks until the stream is fully closed.
    def wait_closed(timeout : Time::Span? = nil) : Bool
      @connection.synchronize do
        deadline = timeout.try { |t| Time.instant + t }
        until @state.closed?
          if deadline
            remaining = deadline - Time.instant
            return false if remaining <= Time::Span.zero
            @cond.wait(@connection.mutex, remaining)
          else
            @cond.wait(@connection.mutex)
          end
        end
        true
      end
    end

    # Registers a callback invoked (in a new fiber) once the stream closes.
    def on_close(&block : Stream ->) : Nil
      run_now = @connection.synchronize do
        if @state.closed?
          true
        else
          @close_callbacks << block
          false
        end
      end
      block.call(self) if run_now
    end

    def closed? : Bool
      @connection.synchronize { @state.closed? }
    end

    def end_stream_sent? : Bool
      @connection.synchronize { @end_stream_sent }
    end

    def end_stream_received? : Bool
      @connection.synchronize { @end_stream_received }
    end

    def headers_sent? : Bool
      @connection.synchronize { @headers_sent }
    end

    # The error that terminated the stream, if any (a `StreamResetError` or
    # `ConnectionClosedError`).
    def error : Exception?
      @connection.synchronize { @error }
    end

    # Returns `true` if the stream was reset (by either endpoint) or failed.
    def reset? : Bool
      @connection.synchronize { !@error.nil? }
    end

    def inspect(io : IO) : Nil
      io << "#<HTTP2::Stream id=" << @id << " state=" << @state << '>'
    end

    # --- Internal state transitions, called with the connection lock held ---

    protected def raise_error! : Nil
      if error = @error
        raise error
      end
    end

    protected def headers_received? : Bool
      !@received_headers.nil?
    end

    protected def remote_closed? : Bool
      @end_stream_received || @state.closed?
    end

    protected def local_closed? : Bool
      @end_stream_sent || @state.closed?
    end

    protected def end_stream_sent_locked? : Bool
      @end_stream_sent
    end

    protected def headers_sent_locked? : Bool
      @headers_sent
    end

    protected def error_locked : Exception?
      @error
    end

    protected def state_locked : State
      @state
    end

    protected def open! : Nil
      @state = State::Open if @state.idle?
    end

    protected def received_headers=(headers : Array({String, String})) : Nil
      @received_headers = headers
      @cond.broadcast
    end

    protected def received_trailers=(trailers : Array({String, String})) : Nil
      @received_trailers = trailers
    end

    protected def push_data(data : Bytes) : Nil
      @data << data
      @cond.broadcast
    end

    protected def clear_data : Nil
      @data.clear
      @data_offset = 0
    end

    protected def mark_headers_sent : Nil
      @headers_sent = true
    end

    # Records that END_STREAM was sent. Returns `true` if the stream is now
    # closed.
    protected def mark_end_stream_sent : Bool
      @end_stream_sent = true
      case @state
      when State::Open
        @state = State::HalfClosedLocal
        false
      when State::HalfClosedRemote
        true
      else
        false
      end
    end

    # Records that END_STREAM was received. Returns `true` if the stream is
    # now closed.
    protected def mark_end_stream_received : Bool
      @end_stream_received = true
      @cond.broadcast
      case @state
      when State::Open
        @state = State::HalfClosedRemote
        false
      when State::HalfClosedLocal
        true
      else
        false
      end
    end

    protected def mark_closed(error : Exception?) : Array(Proc(Stream, Nil))
      @state = State::Closed
      @error ||= error
      clear_data if error && !@end_stream_received
      @cond.broadcast
      callbacks = @close_callbacks
      @close_callbacks = [] of Proc(Stream, Nil)
      callbacks
    end

    # An `IO` over the receiving side of a stream.
    class Body < IO
      def initialize(@stream : Stream)
      end

      def read(slice : Bytes) : Int32
        @stream.read(slice)
      end

      def write(slice : Bytes) : NoReturn
        raise IO::Error.new("Stream body is read-only")
      end
    end
  end
end
