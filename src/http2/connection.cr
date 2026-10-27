module HTTP2
  # An HTTP/2 connection (RFC 9113) over an arbitrary bidirectional `IO`.
  #
  # A connection runs three fibers: a reader that parses and processes
  # incoming frames, a writer that serializes outgoing frames from a queue
  # and a timer that drives keepalive, connection lifetime limits and close
  # timeouts (see `ConnectionOptions`). All connection and stream state is
  # protected by a single mutex, which is never held while performing socket
  # IO, so a peer that stops reading can never block frame processing.
  #
  # The same class implements both endpoints; `role` selects the client or
  # server specific behaviour (stream identifier parity, request vs. response
  # validation and connection preface handling).
  class Connection
    Log = ::Log.for("http2.connection")

    CLIENT_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".to_slice

    # Upper bound on DATA octets queued for writing before senders block.
    MAX_QUEUED_DATA = 1 << 20
    # Number of closed stream identifiers remembered for error reporting.
    CLOSED_STREAMS_TRACKED = 1024
    # Without `ConnectionOptions#permit_without_stream`, PINGs received
    # without active streams count as strikes unless this far apart.
    IDLE_PING_INTERVAL = 2.hours
    # Lower bound of the default `ConnectionOptions#max_running_handlers`.
    MIN_HANDLER_CAP = 100

    enum Role
      Client
      Server
    end

    # Why a stream was closed. Used to pick the correct reaction to frames
    # arriving on closed streams (RFC 9113 section 5.1).
    enum CloseReason
      EndStream
      ResetSent
      ResetReceived
    end

    # Progress of a graceful shutdown initiated by this endpoint.
    private enum GoawayState
      # No GOAWAY sent.
      None
      # The first GOAWAY (last stream identifier 2^31-1) and a PING were
      # sent; waiting for the PING ACK.
      Draining
      # The final GOAWAY with the real last stream identifier was sent.
      Final
    end

    getter role : Role
    getter io : IO
    getter local_settings : Settings
    @options : ConnectionOptions
    getter mutex = Mutex.new

    # Invoked (in a new fiber) for every stream initiated by the peer once
    # its header block was received and validated. Server role only.
    property on_stream : Proc(Stream, Nil)? = nil

    # Invoked once the connection has fully closed. Setting it replaces the
    # previously set callback but not the ones added with `#on_close(&)`.
    property on_close : Proc(Connection, Nil)? = nil

    # The peer's address, if known (set by `Server` for socket connections).
    property remote_address : String? = nil

    # The local address, if known.
    property local_address : String? = nil

    # A process-wide unique identifier (used by channelz).
    getter id : Int64 = ConnectionMetrics.next_id

    # Activity counters (see `ConnectionMetrics`).
    getter metrics = ConnectionMetrics.new

    # When the connection was created.
    getter created_at : Time = Time.utc

    # The connection-level send window (octets the peer currently allows us
    # to send).
    def send_window : Int64
      synchronize { @send_window }
    end

    # The connection-level receive window (octets we currently allow the
    # peer to send).
    def receive_window : Int64
      synchronize { @recv_window }
    end

    # The socket underlying `io`, used to forcibly shut the transport down
    # (e.g. on keepalive timeout or when the peer stops reading). Defaults
    # to `io` itself when it is a `Socket`; set it when `io` wraps a socket
    # (TLS, buffering wrappers).
    property raw_socket : Socket? = nil

    @remote_settings : Settings = Settings.new
    @streams = {} of UInt32 => Stream
    @closed_streams = {} of UInt32 => CloseReason
    @closed_stream_order = Deque(UInt32).new
    @last_peer_stream_id = 0_u32
    @next_stream_id : UInt32
    @active_local_streams = 0
    @active_peer_streams = 0
    @running_handlers = 0

    @send_window : Int64 = Settings::DEFAULT_INITIAL_WINDOW_SIZE.to_i64
    @recv_window : Int64 = Settings::DEFAULT_INITIAL_WINDOW_SIZE.to_i64
    @pending_connection_credit : Int64 = 0
    @send_cond = Condition.new

    @encoder : HPACK::Encoder
    @decoder : HPACK::Decoder
    @header_block : IO::Memory? = nil
    @header_block_frame : HeadersFrame? = nil

    @write_queue = Deque(Frame).new
    @write_cond = Condition.new
    @queued_data_bytes = 0
    @queued_control_frames = 0
    @writer_done = Channel(Nil).new(1)
    @reader_done = Channel(Nil).new(1)
    @writer_finished = false
    # Frames written so far; lets the close watchdog tell a slow peer from
    # one that stopped reading.
    @frames_written = Atomic(Int64).new(0)
    @close_progress_mark = 0_i64

    @preface_received = false
    @remote_settings_received = false
    @settings_cond = Condition.new
    @close_callbacks = [] of Proc(Connection, Nil)
    @goaway_callbacks = [] of Proc(GoawayFrame, Nil)
    @settings_sent_at = Deque(Time::Instant).new
    @goaway_sent = false
    @goaway_state = GoawayState::None
    @goaway_last_stream_id = MAX_STREAM_ID
    @goaway_received : GoawayFrame? = nil
    @closing = false
    @closing_since : Time::Instant? = nil
    @closed = false
    @transport_aborted = false
    @close_error : Exception? = nil
    @closed_channel = Channel(Nil).new
    @pings = {} of UInt64 => Channel(Bool)

    {% if flag?(:execution_context) %}
      @io_context : Fiber::ExecutionContext? = nil
    {% end %}

    # Timers (see `#timer_loop`).
    @timer_cond = Condition.new
    @last_read_at : Time::Instant
    @idle_since : Time::Instant? = nil
    @age_deadline : Time::Instant? = nil
    @force_close_at : Time::Instant? = nil
    @keepalive_ping : UInt64? = nil
    @keepalive_ping_sent_at : Time::Instant? = nil
    @drain_ping : UInt64? = nil
    @drain_deadline : Time::Instant? = nil

    # Keepalive enforcement.
    @ping_strikes = 0
    @last_ping_at : Time::Instant? = nil
    @reset_ping_strikes = false

    # Flood protection. `@payload_batches` counts written batches that
    # contained DATA or HEADERS; the marks remember its value when the last
    # PING / WINDOW_UPDATE was received.
    @payload_batches = 0_i64
    @ping_payload_mark = 0_i64
    @window_update_payload_mark = 0_i64
    @reset_counter : ResetTracker?
    @ping_counter : RateCounter?
    @settings_counter : RateCounter?
    @empty_frame_counter : RateCounter?
    @priority_counter : RateCounter?
    @window_update_counter : RateCounter?

    # *connection_window_size* is the receive window advertised for the
    # connection as a whole; the per-stream receive window is
    # `local_settings.initial_window_size`.
    def initialize(@io : IO, @role : Role, @local_settings : Settings = Settings.new,
                   @connection_window_size : Int32 = 65_535, @options : ConnectionOptions = ConnectionOptions.new)
      @next_stream_id = client? ? 1_u32 : 2_u32
      @encoder = HPACK::Encoder.new
      @decoder = HPACK::Decoder.new(
        @local_settings.header_table_size.to_i32,
        (@local_settings.max_header_list_size || Int32::MAX).to_i32.clamp(0, Int32::MAX))
      if io = @io.as?(IO::Buffered)
        io.sync = false
      end
      @raw_socket = @io.as?(Socket)
      @serialize_io = @io.is_a?(OpenSSL::SSL::Socket)
      now = Time.instant
      @last_read_at = now
      @idle_since = now
      if age = @options.max_connection_age
        jitter = @options.max_connection_age_jitter
        factor = jitter > 0 ? 1.0 + Random.rand(-jitter..jitter) : 1.0
        @age_deadline = now + age * factor
      end
      @reset_counter = @options.max_peer_resets.try { |limit| ResetTracker.new(limit) }
      @ping_counter = @options.max_ping_rate.try { |limit| RateCounter.new(limit) }
      @settings_counter = @options.max_settings_rate.try { |limit| RateCounter.new(limit) }
      @empty_frame_counter = @options.max_empty_frame_rate.try { |limit| RateCounter.new(limit) }
      @priority_counter = @options.max_priority_rate.try { |limit| RateCounter.new(limit) }
      @window_update_counter = @options.max_window_update_rate.try { |limit| RateCounter.new(limit) }
      # Queue the connection preface frames immediately so that they precede
      # any stream opened before the connection fibers start.
      enqueue_initial_frames
    end

    def client? : Bool
      @role.client?
    end

    def server? : Bool
      @role.server?
    end

    def synchronize(&)
      @mutex.synchronize { yield }
    end

    # The settings advertised by the peer.
    def remote_settings : Settings
      synchronize { @remote_settings }
    end

    # Spawns the connection's reader and writer fibers and returns.
    def start : self
      spawn(name: "http2-connection") { run }
      self
    end

    # Runs the connection in the current fiber until it closes.
    #
    # With execution contexts (`-Dexecution_context`), a connection whose
    # `#serialize_io?` is set runs entirely (reader, writer, timer and stream
    # handlers) on a single threaded context shared round-robin with other
    # such connections; otherwise everything runs in the caller's context.
    def run : Nil
      {% if flag?(:execution_context) %}
        if @serialize_io && (context = IOAffinity.next_context)
          @io_context = context
          done = Channel(Nil).new(1)
          context.spawn(name: "http2-connection") do
            run_fibers
          ensure
            done.send(nil)
          end
          # Waking a fiber of another context can be missed by Crystal
          # 1.19's scheduler; re-check periodically.
          until @closed_channel.closed?
            select
            when done.receive
              break
            when timeout(1.second)
            end
          end
          return
        end
      {% end %}
      run_fibers
    end

    # Whether the reader, writer, timer and handler fibers must run on a
    # single thread. Only relevant with execution contexts; defaults to
    # `true` for `OpenSSL::SSL::Socket`, which must not be used from two
    # threads at once (`SSL_read` suspends inside the BIO while `SSL_write`
    # runs). Stream handlers then run on that thread too (concurrently, not
    # in parallel), because fibers spawned into another context from it can
    # be left unscheduled by Crystal 1.19's scheduler.
    property? serialize_io : Bool = false

    private def run_fibers : Nil
      spawn(name: "http2-writer") { writer_loop }
      spawn(name: "http2-timer") { timer_loop }

      begin
        read_client_preface if server? && !@preface_received
        read_loop
        synchronize { start_closing_locked(ConnectionClosedError.new("Connection closed by peer")) }
      rescue e : ConnectionError
        terminate(e.code, e.message)
      rescue e : IO::Error | IO::EOFError | OpenSSL::SSL::Error
        synchronize { start_closing_locked(ConnectionClosedError.new("Connection lost: #{e.message}")) }
      rescue e
        Log.error(exception: e) { "Unexpected error while processing the connection" }
        terminate(ErrorCode::INTERNAL_ERROR, e.message)
      end
      @reader_done.send(nil)
      @writer_done.receive
      finish_close
    end

    # Returns `true` once the connection started closing; no new streams can
    # be created.
    def closed? : Bool
      synchronize { @closing }
    end

    # Returns `true` if the connection can be used to open new streams.
    def available? : Bool
      synchronize { !@closing && @goaway_received.nil? && !@goaway_sent && @next_stream_id <= MAX_STREAM_ID }
    end

    # Blocks until the connection has completely closed.
    def wait_closed : Nil
      @closed_channel.receive?
    end

    # The error the connection was closed with, once closing.
    def close_error : Exception?
      synchronize { @close_error }
    end

    # The number of open streams.
    def active_streams : Int32
      synchronize { @streams.size }
    end

    # The number of peer initiated streams whose handler (`on_stream`) is
    # still running, including handlers of streams that are already closed.
    def running_handlers : Int32
      synchronize { @running_handlers }
    end

    # The GOAWAY frame received from the peer, if any.
    def goaway_received : GoawayFrame?
      synchronize { @goaway_received }
    end

    # The connection's options.
    def options : ConnectionOptions
      synchronize { @options }
    end

    # Configures keepalive pings (see `ConnectionOptions#keepalive_time`).
    # May be called at any time, also after the connection started; `nil`
    # disables keepalive.
    def configure_keepalive(time : Time::Span?, timeout : Time::Span = 20.seconds, permit_without_calls : Bool = false) : Nil
      synchronize do
        @options.keepalive_time = time
        @options.keepalive_timeout = timeout
        @options.keepalive_permit_without_calls = permit_without_calls
        @timer_cond.broadcast
      end
    end

    # Registers a callback invoked (in a new fiber) once the connection has
    # fully closed, in addition to `#on_close=`. Runs immediately if the
    # connection is closed already.
    def on_close(&block : Connection ->) : Nil
      run_now = synchronize do
        @close_callbacks << block unless @closed
        @closed
      end
      block.call(self) if run_now
    end

    # Registers a callback invoked (in a new fiber) for every GOAWAY frame
    # received from the peer, after streams above its last stream identifier
    # failed with `RefusedStreamError`. The connection is no longer
    # `#available?` at that point.
    def on_goaway(&block : GoawayFrame ->) : Nil
      synchronize { @goaway_callbacks << block }
    end

    # Returns `true` once the peer's first SETTINGS frame was received (the
    # peer's connection preface is complete).
    def remote_settings_received? : Bool
      synchronize { @remote_settings_received }
    end

    # Waits until the peer's SETTINGS arrived. Returns `false` if *timeout*
    # elapsed or the connection closed first.
    def wait_for_remote_settings(timeout : Time::Span) : Bool
      deadline = Time.instant + timeout
      synchronize do
        until @remote_settings_received
          return false if @closing
          remaining = deadline - Time.instant
          return false if remaining <= Time::Span.zero
          @settings_cond.wait(@mutex, remaining)
        end
        true
      end
    end

    # Opens a new locally initiated stream by sending *headers*. Blocks while
    # the peer's SETTINGS_MAX_CONCURRENT_STREAMS limit is reached. Raises
    # `HeaderListSizeError` (without opening a stream) if *headers* exceed
    # the peer's SETTINGS_MAX_HEADER_LIST_SIZE.
    def open_stream(headers : Array({String, String}), end_stream : Bool = false) : Stream
      synchronize do
        loop do
          raise ConnectionClosedError.new if @closing
          if @goaway_received || @goaway_sent
            raise RefusedStreamError.new("Connection is shutting down (GOAWAY)")
          end
          raise RefusedStreamError.new("Stream identifiers exhausted") if @next_stream_id > MAX_STREAM_ID
          max = @remote_settings.max_concurrent_streams
          break if max.nil? || @active_local_streams < max
          @send_cond.wait(@mutex)
        end
        check_header_list_size(headers)

        id = @next_stream_id
        @next_stream_id += 2
        stream = Stream.new(self, id, @remote_settings.initial_window_size.to_i64, @local_settings.initial_window_size.to_i64)
        stream.open!
        stream.head_request = headers.any? { |(name, value)| name == ":method" && value == "HEAD" }
        add_stream_locked(stream)
        @active_local_streams += 1
        enqueue_header_block_locked(id, headers, end_stream)
        stream.mark_headers_sent
        if end_stream && stream.mark_end_stream_sent
          close_stream_locked(stream, CloseReason::EndStream)
        end
        stream
      end
    end

    # Sends a PING and waits for the acknowledgement. Returns the round trip
    # time.
    def ping(timeout : Time::Span = 10.seconds) : Time::Span
      data = Random::Secure.random_bytes(8)
      key = IO::ByteFormat::BigEndian.decode(UInt64, data)
      channel = Channel(Bool).new(1)
      synchronize do
        raise ConnectionClosedError.new if @closing
        @pings[key] = channel
        enqueue_locked(PingFrame.new(data))
      end
      started = Time.instant
      select
      when acked = channel.receive?
        raise ConnectionClosedError.new unless acked
        Time.instant - started
      when timeout(timeout)
        synchronize { @pings.delete(key) }
        raise ConnectionClosedError.new("PING timed out", ErrorCode::NO_ERROR)
      end
    end

    # Starts a graceful shutdown and waits up to *timeout* for active
    # streams to finish, then closes the connection.
    #
    # A server first sends GOAWAY with the maximum stream identifier
    # together with a PING; once the PING is acknowledged (so every stream
    # the client opened before seeing the GOAWAY has arrived) it sends the
    # final GOAWAY carrying the last processed stream identifier. Streams
    # above it fail on the client with the retry safe `RefusedStreamError`.
    def shutdown(timeout : Time::Span = 10.seconds) : Nil
      synchronize do
        return if @closing
        begin_graceful_shutdown_locked
      end
      select
      when @closed_channel.receive?
        return
      when timeout(timeout)
        close
      end
      # The writer may be blocked on a peer that stopped reading; give it
      # `close_timeout` to flush GOAWAY, then shut the transport down so the
      # connection cannot linger forever.
      select
      when @closed_channel.receive?
      when timeout(@options.close_timeout)
        synchronize { abort_transport_locked }
      end
    end

    # Starts a graceful shutdown (see `#shutdown`) without waiting for it.
    def drain : Nil
      synchronize { begin_graceful_shutdown_locked }
    end

    # Immediately closes the connection, sending GOAWAY with *code*.
    def close(code : ErrorCode = ErrorCode::NO_ERROR, message : String? = nil) : Nil
      terminate(code, message)
    end

    # :nodoc:
    # Marks the client connection preface as already consumed (by
    # protocol detection). Must be called before `#run`.
    def preface_received! : Nil
      @preface_received = true
    end

    # :nodoc:
    # Overrides the next locally initiated stream identifier (for tests of
    # stream identifier exhaustion).
    def next_stream_id=(id : UInt32) : Nil
      synchronize { @next_stream_id = id }
    end

    # Serves an HTTP/1.1 request that was upgraded with `Upgrade: h2c`
    # (RFC 7540 section 3.2) as stream 1. *fields* are the request's HTTP/2
    # header fields, *settings* the decoded `HTTP2-Settings` header and
    # *body* the complete request body. Server role only; must be called
    # before `#run`, after `#on_stream` was set.
    def accept_upgrade(fields : Array({String, String}), settings : Array({UInt16, UInt32}), body : Bytes = Bytes.empty) : Stream
      synchronize do
        apply_remote_settings_locked(settings)
        @remote_settings_received = true
        request = HeaderValidation.validate_request(1_u32, fields)
        @last_peer_stream_id = 1_u32
        stream = Stream.new(self, 1_u32, @remote_settings.initial_window_size.to_i64, @local_settings.initial_window_size.to_i64)
        stream.open!
        stream.content_length = request.content_length
        stream.received_headers = fields
        add_stream_locked(stream)
        @active_peer_streams += 1
        stream.data_received += body.size
        stream.push_data(body) unless body.empty?
        end_stream_received_locked(stream)
        dispatch_stream_locked(stream)
        stream
      end
    end

    # --- Stream operations (called by Stream) ---

    protected def send_headers(stream : Stream, headers : Array({String, String}), end_stream : Bool) : Nil
      synchronize do
        check_writable_locked(stream)
        begin
          check_header_list_size(headers)
        rescue e : HeaderListSizeError
          enqueue_locked(RstStreamFrame.new(stream.id, ErrorCode::INTERNAL_ERROR))
          close_stream_locked(stream, CloseReason::ResetSent, StreamResetError.new(stream.id, ErrorCode::INTERNAL_ERROR, remote: false))
          raise e
        end
        enqueue_header_block_locked(stream.id, headers, end_stream)
        stream.mark_headers_sent
        if end_stream && stream.mark_end_stream_sent
          close_stream_locked(stream, CloseReason::EndStream)
        end
      end
    end

    protected def send_data(stream : Stream, data : Bytes, end_stream : Bool) : Nil
      offset = 0
      loop do
        synchronize do
          window = 0_i64
          loop do
            check_writable_locked(stream)
            if offset == data.size
              # Only reached for empty writes.
              return unless end_stream
              enqueue_locked(DataFrame.new(stream.id, Bytes.empty, end_stream: true))
              close_stream_locked(stream, CloseReason::EndStream) if stream.mark_end_stream_sent
              return
            end
            window = Math.min(stream.send_window, @send_window)
            break if window > 0 && @queued_data_bytes < MAX_QUEUED_DATA
            @send_cond.wait(@mutex)
          end

          count = Math.min(Math.min(data.size - offset, window), @remote_settings.max_frame_size.to_i64).to_i32
          chunk = data[offset, count].dup
          offset += count
          last = offset == data.size
          stream.send_window -= count
          @send_window -= count
          @queued_data_bytes += count
          enqueue_locked(DataFrame.new(stream.id, chunk, end_stream: end_stream && last))
          if last
            close_stream_locked(stream, CloseReason::EndStream) if end_stream && stream.mark_end_stream_sent
            return
          end
        end
      end
    end

    protected def reset_stream(stream : Stream, code : ErrorCode) : Nil
      synchronize do
        next if stream.state_locked.closed?
        enqueue_locked(RstStreamFrame.new(stream.id, code))
        close_stream_locked(stream, CloseReason::ResetSent, StreamResetError.new(stream.id, code, remote: false))
      end
    end

    # Called with the lock held when the application consumed *count* octets
    # of body data, returning flow control credit to the peer.
    protected def consumed_data(stream : Stream, count : Int32) : Nil
      return if stream.remote_closed?
      stream.pending_recv_credit += count
      if stream.pending_recv_credit >= Math.max(@local_settings.initial_window_size // 2, 1)
        credit = stream.pending_recv_credit
        stream.pending_recv_credit = 0
        stream.recv_window += credit
        enqueue_locked(WindowUpdateFrame.new(stream.id, credit.to_u32))
      end
    end

    # --- Reading ---

    private def read_client_preface : Nil
      preface = Bytes.new(CLIENT_PREFACE.size)
      @io.read_fully(preface)
      unless preface == CLIENT_PREFACE
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid connection preface")
      end
    end

    private def read_loop : Nil
      first = true
      loop do
        frame = begin
          Frame.read(@io, @local_settings.max_frame_size.to_i32)
        rescue e : StreamError
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, e.message) if first || synchronize { @header_block }
          synchronize { reset_stream_id_locked(e.stream_id, e.code) unless @closing }
          next
        end
        break unless frame

        if first
          unless frame.is_a?(SettingsFrame) && !frame.ack?
            raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "First frame must be SETTINGS")
          end
          first = false
        end

        synchronize do
          # Once closing, frames are read (so the peer can still receive
          # our final frames) but no longer processed.
          next if @closing
          @last_read_at = Time.instant
          begin
            process(frame)
          rescue e : StreamError
            reset_stream_id_locked(e.stream_id, e.code)
          end
        end
      end
    end

    private def process(frame : Frame) : Nil
      if stream_id = @header_block_frame.try(&.stream_id)
        unless frame.is_a?(ContinuationFrame) && frame.stream_id == stream_id
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Expected CONTINUATION frame for stream #{stream_id}")
        end
      end

      case frame
      when DataFrame         then process_data(frame)
      when HeadersFrame      then process_headers(frame)
      when PriorityFrame     then process_priority(frame)
      when RstStreamFrame    then process_rst_stream(frame)
      when SettingsFrame     then process_settings(frame)
      when PushPromiseFrame  then raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Unexpected PUSH_PROMISE frame")
      when PingFrame         then process_ping(frame)
      when GoawayFrame       then process_goaway(frame)
      when WindowUpdateFrame then process_window_update(frame)
      when ContinuationFrame then process_continuation(frame)
      else
        # Unknown frame types are ignored (section 4.1 and 5.5), but they
        # carry nothing useful and count towards the empty frame limit.
        check_rate(@empty_frame_counter, "Unknown frame")
      end
    end

    # Raises ENHANCE_YOUR_CALM if *counter* exceeds its limit.
    private def check_rate(counter : RateCounter?, what : String) : Nil
      if counter && !counter.record
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "#{what} flood")
      end
    end

    private def process_data(frame : DataFrame) : Nil
      id = frame.stream_id
      size = frame.flow_controlled_size.to_i64
      check_rate(@empty_frame_counter, "Empty DATA frame") if frame.data.empty? && !frame.end_stream?

      if size > @recv_window
        raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "DATA exceeds connection flow control window")
      end
      @recv_window -= size
      credit_connection_locked(size)

      stream = @streams[id]?
      unless stream
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "DATA frame on idle stream #{id}") if idle?(id)
        # Frames in flight after we reset a stream are ignored.
        return if @closed_streams[id]?.try(&.reset_sent?)
        raise StreamError.new(id, ErrorCode::STREAM_CLOSED, "DATA frame on closed stream #{id}")
      end

      if stream.remote_closed?
        raise StreamError.new(id, ErrorCode::STREAM_CLOSED, "DATA frame on half-closed stream #{id}")
      end
      unless stream.headers_received?
        raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "DATA frame before HEADERS on stream #{id}")
      end
      if size > stream.recv_window
        raise StreamError.new(id, ErrorCode::FLOW_CONTROL_ERROR, "DATA exceeds stream flow control window")
      end
      stream.recv_window -= size

      stream.data_received += frame.data.size
      if (length = stream.content_length) && stream.data_received > length
        raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "DATA exceeds content-length")
      end

      stream.push_data(frame.data) unless frame.data.empty?
      # Padding is never seen by the application; return its credit now.
      consumed_data(stream, frame.padding) if frame.padding > 0

      if frame.end_stream?
        if (length = stream.content_length) && stream.data_received != length
          raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "DATA does not match content-length")
        end
        end_stream_received_locked(stream)
      end
    end

    private def process_headers(frame : HeadersFrame) : Nil
      if frame.end_headers?
        complete_header_block(frame, frame.fragment)
      else
        check_rate(@empty_frame_counter, "Empty HEADERS frame") if frame.fragment.empty?
        @header_block_frame = frame
        block = IO::Memory.new
        block.write(frame.fragment)
        @header_block = block
      end
    end

    private def process_continuation(frame : ContinuationFrame) : Nil
      headers_frame = @header_block_frame
      block = @header_block
      unless headers_frame && block
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Unexpected CONTINUATION frame")
      end
      check_rate(@empty_frame_counter, "Empty CONTINUATION frame") if frame.fragment.empty? && !frame.end_headers?
      block.write(frame.fragment)
      if block.size > max_header_block_size
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "Header block too large")
      end
      if frame.end_headers?
        @header_block_frame = nil
        @header_block = nil
        complete_header_block(headers_frame, block.to_slice)
      end
    end

    private def max_header_block_size : Int32
      limit = (@local_settings.max_header_list_size || (1 << 20)).to_i64 * 2
      Math.max(limit, 65_536_i64).clamp(0_i64, Int32::MAX.to_i64).to_i32
    end

    private def decode_header_block(block : Bytes) : {Array({String, String}), Bool}
      {@decoder.decode(block), false}
    rescue HPACK::HeaderListTooLargeError
      {[] of {String, String}, true}
    rescue e : HPACK::DecompressionError
      raise ConnectionError.new(ErrorCode::COMPRESSION_ERROR, e.message)
    end

    private def complete_header_block(frame : HeadersFrame, block : Bytes) : Nil
      # Always decode first so the HPACK state stays synchronised, even if
      # the stream is subsequently rejected.
      fields, too_large = decode_header_block(block)
      id = frame.stream_id

      if stream = @streams[id]?
        receive_headers_on_stream(stream, frame, fields, too_large)
        return
      end

      if idle?(id)
        unless peer_initiated?(id)
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "HEADERS on idle stream #{id} with invalid identifier")
        end
        open_peer_stream(frame, fields, too_large)
        return
      end

      case @closed_streams[id]?
      when CloseReason::ResetSent
        # The peer may not have seen our RST_STREAM yet.
        return
      when CloseReason::ResetReceived, CloseReason::EndStream
        raise ConnectionError.new(ErrorCode::STREAM_CLOSED, "HEADERS on closed stream #{id}")
      else
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "HEADERS with stream identifier #{id} lower than an opened stream")
      end
    end

    private def open_peer_stream(frame : HeadersFrame, fields, too_large : Bool) : Nil
      id = frame.stream_id
      @last_peer_stream_id = id

      # Streams created after we sent the final GOAWAY are ignored.
      return if @goaway_sent && id > @goaway_last_stream_id

      if (priority = frame.priority) && priority.stream_dependency == id
        raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "Stream #{id} depends on itself")
      end
      if @settings_sent_at.empty? && (max = @local_settings.max_concurrent_streams) && @active_peer_streams >= max
        refuse_stream_locked(id, "Concurrent stream limit reached")
      end
      if (cap = handler_cap) && @running_handlers >= cap
        refuse_stream_locked(id, "Too many running handlers")
      end
      raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "Header list too large") if too_large

      request = HeaderValidation.validate_request(id, fields)
      if frame.end_stream? && (length = request.content_length) && length != 0
        raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "content-length without body")
      end

      stream = Stream.new(self, id, @remote_settings.initial_window_size.to_i64, @local_settings.initial_window_size.to_i64)
      stream.open!
      stream.content_length = request.content_length
      stream.received_headers = fields
      add_stream_locked(stream)
      @active_peer_streams += 1
      @reset_counter.try &.stream_opened
      end_stream_received_locked(stream) if frame.end_stream?
      dispatch_stream_locked(stream)

      # The peer cannot open further streams; ask it to reconnect.
      begin_graceful_shutdown_locked if id >= MAX_STREAM_ID - 1
    end

    # Spawns application code (handlers, callbacks) in the connection's
    # context (see `#run`).
    private def spawn_app(name : String, &block : ->) : Nil
      spawn(name: name, &block)
    end

    # Refuses a new peer stream; refusals count towards the reset limit so
    # that a peer cannot churn through streams the server never serves.
    private def refuse_stream_locked(id : UInt32, message : String) : NoReturn
      count_peer_reset_locked
      raise StreamError.new(id, ErrorCode::REFUSED_STREAM, message)
    end

    private def handler_cap : Int32?
      # A client may legitimately exceed SETTINGS_MAX_CONCURRENT_STREAMS
      # before it received our SETTINGS, hence the floor.
      @options.max_running_handlers || @local_settings.max_concurrent_streams.try do |max|
        (max.to_i64 * 4).clamp(MIN_HANDLER_CAP.to_i64, Int32::MAX.to_i64).to_i32
      end
    end

    private def dispatch_stream_locked(stream : Stream) : Nil
      callback = @on_stream
      return unless callback
      @running_handlers += 1
      spawn_app("http2-stream-#{stream.id}") do
        callback.call(stream)
      ensure
        synchronize { @running_handlers -= 1 }
      end
    end

    private def receive_headers_on_stream(stream : Stream, frame : HeadersFrame, fields, too_large : Bool) : Nil
      id = stream.id
      if stream.remote_closed?
        raise StreamError.new(id, ErrorCode::STREAM_CLOSED, "HEADERS on half-closed stream #{id}")
      end
      if (priority = frame.priority) && priority.stream_dependency == id
        raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "Stream #{id} depends on itself")
      end
      raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "Header list too large") if too_large

      if stream.headers_received?
        # Trailers (section 8.1).
        unless frame.end_stream?
          raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "Trailers without END_STREAM")
        end
        stream.received_trailers = HeaderValidation.validate_trailers(id, fields)
        if (length = stream.content_length) && stream.data_received != length
          raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "DATA does not match content-length")
        end
        end_stream_received_locked(stream)
        return
      end

      # Only clients receive response headers on existing streams.
      raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "Unexpected HEADERS") unless client?
      response = HeaderValidation.validate_response(id, fields)
      if 100 <= response.status < 200
        if frame.end_stream?
          raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "Informational response with END_STREAM")
        end
        return
      end
      unless stream.head_request? || response.status == 204 || response.status == 304
        stream.content_length = response.content_length
      end
      stream.received_headers = fields
      end_stream_received_locked(stream) if frame.end_stream?
    end

    private def process_priority(frame : PriorityFrame) : Nil
      check_rate(@priority_counter, "PRIORITY")
      if frame.priority.stream_dependency == frame.stream_id
        raise StreamError.new(frame.stream_id, ErrorCode::PROTOCOL_ERROR, "Stream #{frame.stream_id} depends on itself")
      end
      # Priority signals are otherwise ignored (RFC 9113 section 5.3.2).
    end

    private def process_rst_stream(frame : RstStreamFrame) : Nil
      id = frame.stream_id
      raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "RST_STREAM on idle stream #{id}") if idle?(id)
      stream = @streams[id]?
      # Only resets of streams we were still serving cost us anything.
      count_peer_reset_locked if stream && peer_initiated?(id) && !stream.local_closed?
      if stream
        close_stream_locked(stream, CloseReason::ResetReceived, StreamResetError.new(id, frame.error_code, remote: true))
      end
    end

    # Rapid reset protection (CVE-2023-44487).
    private def count_peer_reset_locked : Nil
      if (tracker = @reset_counter) && !tracker.record
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "Stream reset flood")
      end
    end

    private def process_settings(frame : SettingsFrame) : Nil
      check_rate(@settings_counter, "SETTINGS")
      if frame.ack?
        @settings_sent_at.shift?
        @timer_cond.broadcast
        return
      end
      apply_remote_settings_locked(frame.parameters)
      @remote_settings_received = true
      @settings_cond.broadcast
      enqueue_locked(SettingsFrame.ack)
    end

    private def apply_remote_settings_locked(parameters : Array({UInt16, UInt32})) : Nil
      parameters.each { |(id, value)| Settings.validate(id, value) }
      parameters.each do |(id, value)|
        case SettingIdentifier.from_value?(id)
        when SettingIdentifier::INITIAL_WINDOW_SIZE
          delta = value.to_i64 - @remote_settings.initial_window_size.to_i64
          @streams.each_value do |stream|
            stream.send_window += delta
            if stream.send_window > MAX_WINDOW_SIZE
              raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "SETTINGS_INITIAL_WINDOW_SIZE overflows stream window")
            end
          end
        when SettingIdentifier::HEADER_TABLE_SIZE
          @encoder.peer_max_table_size = value.clamp(0_u32, Int32::MAX.to_u32).to_i32
        end
        @remote_settings.apply(id, value)
      end
      @send_cond.broadcast
    end

    private def process_ping(frame : PingFrame) : Nil
      # PINGs answering our DATA/HEADERS (e.g. grpc-go's BDP estimation)
      # are not flooding.
      if @payload_batches == @ping_payload_mark
        check_rate(@ping_counter, "PING")
      else
        @ping_payload_mark = @payload_batches
      end
      if frame.ack?
        key = IO::ByteFormat::BigEndian.decode(UInt64, frame.data)
        if key == @keepalive_ping
          @keepalive_ping = nil
          @keepalive_ping_sent_at = nil
          @timer_cond.broadcast
        elsif key == @drain_ping
          send_final_goaway_locked if @goaway_state.draining?
        elsif channel = @pings.delete(key)
          channel.send(true)
        end
      else
        enqueue_locked(PingFrame.new(frame.data, ack: true))
        enforce_ping_policy_locked
      end
    end

    # Keepalive enforcement as specified by gRPC (A8/A9) and implemented by
    # grpc-go: PINGs arriving more often than allowed count as strikes;
    # sending DATA or HEADERS resets the strike count.
    private def enforce_ping_policy_locked : Nil
      min_interval = @options.min_ping_interval
      return unless min_interval
      now = Time.instant
      last = @last_ping_at
      @last_ping_at = now
      if @reset_ping_strikes
        @reset_ping_strikes = false
        @ping_strikes = 0
        return
      end
      return unless last
      interval = @streams.empty? && !@options.permit_without_stream? ? IDLE_PING_INTERVAL : min_interval
      @ping_strikes += 1 if now - last < interval
      if @ping_strikes > @options.max_ping_strikes
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "too_many_pings")
      end
    end

    private def process_goaway(frame : GoawayFrame) : Nil
      @goaway_received = frame
      @metrics.goaway_error_code = frame.raw_error_code
      @goaway_callbacks.each { |callback| spawn_app("http2-goaway-callback") { callback.call(frame) } }
      @streams.values.each do |stream|
        if stream.local? && stream.id > frame.last_stream_id
          close_stream_locked(stream, CloseReason::ResetReceived, RefusedStreamError.new("Stream not processed by peer (GOAWAY)"))
        end
      end
      @send_cond.broadcast
      if @streams.empty?
        start_closing_locked(ConnectionClosedError.new("Connection closed by peer (GOAWAY #{frame.error_code})", frame.error_code))
      end
    end

    private def process_window_update(frame : WindowUpdateFrame) : Nil
      # WINDOW_UPDATEs are expected while we send DATA.
      if @payload_batches == @window_update_payload_mark
        check_rate(@window_update_counter, "WINDOW_UPDATE")
      else
        @window_update_payload_mark = @payload_batches
      end
      id = frame.stream_id
      increment = frame.increment.to_i64

      if id == 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "WINDOW_UPDATE with zero increment") if increment == 0
        @send_window += increment
        if @send_window > MAX_WINDOW_SIZE
          raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "Connection flow control window overflow")
        end
      else
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "WINDOW_UPDATE on idle stream #{id}") if idle?(id)
        raise StreamError.new(id, ErrorCode::PROTOCOL_ERROR, "WINDOW_UPDATE with zero increment") if increment == 0
        stream = @streams[id]?
        return unless stream
        stream.send_window += increment
        if stream.send_window > MAX_WINDOW_SIZE
          raise StreamError.new(id, ErrorCode::FLOW_CONTROL_ERROR, "Stream flow control window overflow")
        end
      end
      @send_cond.broadcast
    end

    # --- State helpers (lock held) ---

    private def peer_initiated?(id : UInt32) : Bool
      client? ? id.even? : id.odd?
    end

    private def idle?(id : UInt32) : Bool
      if peer_initiated?(id)
        id > @last_peer_stream_id
      else
        id >= @next_stream_id
      end
    end

    private def check_writable_locked(stream : Stream) : Nil
      stream.raise_error!
      raise ConnectionClosedError.new if @closing
      raise Error.new(ErrorCode::STREAM_CLOSED, "Stream #{stream.id} already closed for sending") if stream.local_closed?
    end

    # Raises `HeaderListSizeError` if *headers* exceed the peer's
    # SETTINGS_MAX_HEADER_LIST_SIZE.
    private def check_header_list_size(headers : Array({String, String})) : Nil
      limit = @remote_settings.max_header_list_size
      return unless limit
      size = headers.sum(0_i64) { |(name, value)| (name.bytesize + value.bytesize + HPACK::ENTRY_OVERHEAD).to_i64 }
      raise HeaderListSizeError.new(size, limit) if size > limit
    end

    private def end_stream_received_locked(stream : Stream) : Nil
      close_stream_locked(stream, CloseReason::EndStream) if stream.mark_end_stream_received
    end

    private def credit_connection_locked(size : Int64) : Nil
      return if size == 0
      @pending_connection_credit += size
      if @pending_connection_credit >= Math.max(@connection_window_size // 2, 1)
        credit = @pending_connection_credit
        @pending_connection_credit = 0
        @recv_window += credit
        enqueue_locked(WindowUpdateFrame.new(0_u32, credit.to_u32))
      end
    end

    private def reset_stream_id_locked(id : UInt32, code : ErrorCode) : Nil
      enqueue_locked(RstStreamFrame.new(id, code))
      if stream = @streams[id]?
        close_stream_locked(stream, CloseReason::ResetSent, StreamResetError.new(id, code, remote: false))
      else
        record_closed_locked(id, CloseReason::ResetSent)
      end
    end

    private def add_stream_locked(stream : Stream) : Nil
      @metrics.record_stream_created(stream.local?)
      @streams[stream.id] = stream
      @idle_since = nil
      @timer_cond.broadcast
    end

    private def close_stream_locked(stream : Stream, reason : CloseReason, error : Exception? = nil) : Nil
      return if stream.state_locked.closed?
      callbacks = stream.mark_closed(error)
      if @streams.delete(stream.id)
        if stream.local?
          @active_local_streams -= 1
        else
          @active_peer_streams -= 1
        end
      end
      record_closed_locked(stream.id, reason)
      @metrics.record_stream_closed(reason.end_stream? && stream.error_locked.nil?)
      @send_cond.broadcast
      callbacks.each { |callback| spawn_app("http2-stream-callback") { callback.call(stream) } }

      if @streams.empty?
        @idle_since = Time.instant
        @timer_cond.broadcast
        close_if_drained_locked
      end
    end

    # Closes an idle connection that cannot be used for new streams.
    private def close_if_drained_locked : Nil
      return if @closing || !@streams.empty?
      if @goaway_state.final? || @goaway_received
        start_closing_locked(ConnectionClosedError.new("Connection shut down"))
      elsif client? && @next_stream_id > MAX_STREAM_ID
        # Stream identifiers are exhausted; `Client` opens a new connection.
        send_final_goaway_locked
      end
    end

    private def record_closed_locked(id : UInt32, reason : CloseReason) : Nil
      @closed_streams[id] = reason
      @closed_stream_order << id
      while @closed_stream_order.size > CLOSED_STREAMS_TRACKED
        @closed_streams.delete(@closed_stream_order.shift)
      end
    end

    # --- Graceful shutdown ---

    private def begin_graceful_shutdown_locked : Nil
      return if @closing || !@goaway_state.none?
      if server?
        @goaway_sent = true
        @goaway_state = GoawayState::Draining
        @goaway_last_stream_id = MAX_STREAM_ID
        enqueue_locked(GoawayFrame.new(MAX_STREAM_ID, ErrorCode::NO_ERROR))
        data = Random::Secure.random_bytes(8)
        @drain_ping = IO::ByteFormat::BigEndian.decode(UInt64, data)
        enqueue_locked(PingFrame.new(data))
        @drain_deadline = Time.instant + @options.shutdown_ping_timeout
        @send_cond.broadcast
        @timer_cond.broadcast
      else
        # A client's peer cannot open streams; one GOAWAY is enough.
        send_final_goaway_locked
      end
    end

    private def send_final_goaway_locked : Nil
      return if @closing || @goaway_state.final?
      @goaway_sent = true
      @goaway_state = GoawayState::Final
      @goaway_last_stream_id = @last_peer_stream_id
      @drain_ping = nil
      @drain_deadline = nil
      enqueue_locked(GoawayFrame.new(@last_peer_stream_id, ErrorCode::NO_ERROR))
      @send_cond.broadcast
      @timer_cond.broadcast
      close_if_drained_locked
    end

    # --- Timers ---

    # Drives keepalive, the SETTINGS timeout, connection idle/age limits and
    # the close timeout. Exits once the writer finished.
    private def timer_loop : Nil
      synchronize do
        until @writer_finished
          now = Time.instant
          deadline = run_timers_locked(now)
          next if deadline && deadline <= now
          @timer_cond.wait(@mutex, deadline.try { |d| d - now })
        end
      end
    end

    # Performs due timer actions and returns the next deadline (or `nil` if
    # there is none). Returns *now* after acting so state is re-evaluated.
    private def run_timers_locked(now : Time::Instant) : Time::Instant?
      if @closing
        written = @frames_written.get
        if written != @close_progress_mark || @closing_since.nil?
          @close_progress_mark = written
          @closing_since = now
        end
        deadline = @closing_since.not_nil! + @options.close_timeout
        return deadline if now < deadline
        abort_transport_locked
        return nil
      end

      next_deadline = nil

      if (timeout = @options.settings_timeout) && (sent = @settings_sent_at.first?)
        deadline = sent + timeout
        if now >= deadline
          terminate_locked(ErrorCode::SETTINGS_TIMEOUT, "SETTINGS not acknowledged within #{timeout}")
          return now
        end
        next_deadline = earliest(next_deadline, deadline)
      end

      if keepalive = @options.keepalive_time
        if sent = @keepalive_ping_sent_at
          deadline = sent + @options.keepalive_timeout
          if now >= deadline
            keepalive_failed_locked
            return now
          end
          next_deadline = earliest(next_deadline, deadline)
        elsif !@streams.empty? || @options.keepalive_permit_without_calls?
          deadline = @last_read_at + keepalive
          if now >= deadline
            send_keepalive_ping_locked(now)
            return now
          end
          next_deadline = earliest(next_deadline, deadline)
        end
      end

      if deadline = @drain_deadline
        if now >= deadline
          send_final_goaway_locked
          return now
        end
        next_deadline = earliest(next_deadline, deadline)
      end

      if @goaway_state.none?
        if (idle = @options.max_connection_idle) && (since = @idle_since)
          deadline = since + idle
          if now >= deadline
            begin_graceful_shutdown_locked
            return now
          end
          next_deadline = earliest(next_deadline, deadline)
        end
        if deadline = @age_deadline
          if now >= deadline
            @force_close_at = @options.max_connection_age_grace.try { |grace| now + grace }
            begin_graceful_shutdown_locked
            return now
          end
          next_deadline = earliest(next_deadline, deadline)
        end
      end

      if deadline = @force_close_at
        if now >= deadline
          terminate_locked(ErrorCode::NO_ERROR, "max_age")
          return now
        end
        next_deadline = earliest(next_deadline, deadline)
      end

      next_deadline
    end

    private def earliest(a : Time::Instant?, b : Time::Instant) : Time::Instant
      a && a < b ? a : b
    end

    private def send_keepalive_ping_locked(now : Time::Instant) : Nil
      data = Random::Secure.random_bytes(8)
      @keepalive_ping = IO::ByteFormat::BigEndian.decode(UInt64, data)
      @keepalive_ping_sent_at = now
      @metrics.keepalives_sent.add(1)
      enqueue_locked(PingFrame.new(data))
    end

    private def keepalive_failed_locked : Nil
      error = ConnectionClosedError.new("Keepalive ping not acknowledged within #{@options.keepalive_timeout}")
      @goaway_sent = true
      @goaway_state = GoawayState::Final
      enqueue_locked(GoawayFrame.new(@last_peer_stream_id, ErrorCode::NO_ERROR, "keepalive_timeout".to_slice))
      start_closing_locked(error)
      # The peer is unresponsive; do not wait for our frames to drain.
      abort_transport_locked
    end

    # --- Writing ---

    private def enqueue_initial_frames : Nil
      synchronize do
        enqueue_locked(SettingsFrame.new(@local_settings.to_parameters))
        @settings_sent_at << Time.instant
        if @connection_window_size > Settings::DEFAULT_INITIAL_WINDOW_SIZE
          increment = @connection_window_size - Settings::DEFAULT_INITIAL_WINDOW_SIZE.to_i32
          @recv_window += increment
          enqueue_locked(WindowUpdateFrame.new(0_u32, increment.to_u32))
        end
      end
    end

    private def enqueue_locked(frame : Frame) : Nil
      @write_queue << frame
      @write_cond.broadcast
      if control_frame?(frame)
        @queued_control_frames += 1
        control_queue_overflow_locked if @queued_control_frames > @options.max_queued_control_frames
      end
    end

    private def control_frame?(frame : Frame) : Bool
      !frame.is_a?(DataFrame) && !frame.is_a?(HeadersFrame) && !frame.is_a?(ContinuationFrame)
    end

    # The peer keeps provoking control frames but does not read them.
    private def control_queue_overflow_locked : Nil
      return if @closing
      @goaway_sent = true
      @goaway_state = GoawayState::Final
      start_closing_locked(ConnectionClosedError.new("Too many queued control frames (peer not reading)", ErrorCode::ENHANCE_YOUR_CALM))
      abort_transport_locked
    end

    private def enqueue_header_block_locked(stream_id : UInt32, headers : Array({String, String}), end_stream : Bool) : Nil
      block = @encoder.encode(headers)
      max = @remote_settings.max_frame_size.to_i32
      if block.size <= max
        enqueue_locked(HeadersFrame.new(stream_id, block, end_stream: end_stream, end_headers: true))
        return
      end
      enqueue_locked(HeadersFrame.new(stream_id, block[0, max], end_stream: end_stream, end_headers: false))
      offset = max
      while offset < block.size
        count = Math.min(max, block.size - offset)
        enqueue_locked(ContinuationFrame.new(stream_id, block[offset, count], end_headers: offset + count == block.size))
        offset += count
      end
    end

    private def writer_loop : Nil
      @io.write(CLIENT_PREFACE) if client?
      batch = [] of Frame
      loop do
        synchronize do
          while @write_queue.empty? && !@closing
            @write_cond.wait(@mutex)
          end
          batch.concat(@write_queue)
          @write_queue.clear
        end
        break if batch.empty?

        data_bytes = 0
        control_frames = 0
        payload = false
        batch.each do |frame|
          frame.write(@io)
          @frames_written.add(1)
          case frame
          when DataFrame
            data_bytes += frame.data.size
            payload = true
          when HeadersFrame, ContinuationFrame
            payload = true
          else
            control_frames += 1
          end
        end
        @io.flush
        batch.clear

        synchronize do
          @queued_control_frames -= control_frames
          # Pings received while we are sending DATA or HEADERS do not
          # count as strikes (keepalive enforcement).
          if payload
            @reset_ping_strikes = true
            @payload_batches += 1
          end
          if data_bytes > 0
            @queued_data_bytes -= data_bytes
            @send_cond.broadcast
          end
        end
      end
    rescue e : IO::Error | OpenSSL::SSL::Error
      synchronize { start_closing_locked(ConnectionClosedError.new("Connection lost: #{e.message}")) }
    ensure
      close_transport
      synchronize do
        @writer_finished = true
        @timer_cond.broadcast
      end
      @writer_done.send(nil)
    end

    # Closes the IO once the reader stopped using it. Closing a socket
    # while a fiber on another thread starts waiting on it can corrupt
    # Crystal 1.19's event loop (with execution contexts), so the reader is
    # first woken up by shutting down the socket's read side.
    private def close_transport : Nil
      if socket = @raw_socket
        socket.close_read rescue nil
        select
        when @reader_done.receive
        when timeout(@options.close_timeout)
        end
      end
      @io.close rescue nil
    end

    # Unblocks a reader or writer stuck on a peer that does not read or
    # respond: shutting the socket down makes pending reads and writes
    # fail; the writer then closes the IO.
    private def abort_transport_locked : Nil
      return if @transport_aborted
      @transport_aborted = true
      if socket = @raw_socket
        socket.close_write rescue nil
        socket.close_read rescue nil
      else
        # Close on the IO fibers' thread (see `#serialize_io?`).
        io = @io
        {% if flag?(:execution_context) %}
          if context = @io_context
            context.spawn(name: "http2-abort") { io.close rescue nil }
            return
          end
        {% end %}
        spawn(name: "http2-abort") { io.close rescue nil }
      end
    end

    # Sends GOAWAY with *code* and closes the connection.
    private def terminate(code : ErrorCode, message : String?) : Nil
      synchronize { terminate_locked(code, message) }
    end

    private def terminate_locked(code : ErrorCode, message : String?) : Nil
      return if @closing
      @goaway_sent = true
      @goaway_state = GoawayState::Final
      debug = (message || "").to_slice
      enqueue_locked(GoawayFrame.new(@last_peer_stream_id, code, debug))
      error = if code.no_error?
                ConnectionClosedError.new
              else
                ConnectionClosedError.new("Connection error: #{code} #{message}", code)
              end
      start_closing_locked(error)
    end

    private def start_closing_locked(error : Exception) : Nil
      return if @closing
      Log.debug { "#{@role} connection closing: #{error.message}" }
      @closing = true
      @closing_since = Time.instant
      @close_progress_mark = @frames_written.get
      @close_error = error
      @streams.values.each do |stream|
        close_stream_locked(stream, CloseReason::ResetReceived, error)
      end
      @pings.each_value &.close
      @pings.clear
      @write_cond.broadcast
      @send_cond.broadcast
      @timer_cond.broadcast
      @settings_cond.broadcast
    end

    private def finish_close : Nil
      callbacks = synchronize do
        return if @closed
        @closed = true
        @close_callbacks.dup
      end
      @closed_channel.close
      @on_close.try &.call(self)
      callbacks.each { |callback| spawn_app("http2-close-callback") { callback.call(self) } }
    end
  end

  {% if flag?(:execution_context) %}
    # :nodoc:
    # Single threaded execution contexts that run the IO fibers of
    # connections whose IO must not be used from two threads at once.
    # Connections are distributed round-robin so that different connections
    # still run in parallel.
    module IOAffinity
      @@contexts = [] of Fiber::ExecutionContext::Concurrent
      @@next = Atomic(Int32).new(0)
      @@mutex = Mutex.new

      def self.size : Int32
        Fiber::ExecutionContext.default_workers_count
      end

      def self.next_context : Fiber::ExecutionContext::Concurrent
        index = @@next.add(1) % size
        @@mutex.synchronize do
          while @@contexts.size <= index
            @@contexts << Fiber::ExecutionContext::Concurrent.new("http2-io-#{@@contexts.size}")
          end
          @@contexts[index]
        end
      end
    end
  {% end %}
end
