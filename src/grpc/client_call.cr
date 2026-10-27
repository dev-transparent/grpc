module GRPC
  # The client side of a single call: sends request messages and receives
  # response messages, and turns the response trailers (or stream errors)
  # into a `Status`.
  #
  # A call is carried out by one or more *attempts*, each an HTTP/2 stream
  # on a connection picked by the channel's load balancing policy. Sent
  # messages are buffered (up to the channel's per-call and channel-wide
  # limits) until the call *commits* to an attempt, i.e. receives response
  # headers, so that failed attempts can be retried transparently or as
  # allowed by the method's retry or hedging policy
  # (https://github.com/grpc/proposal/blob/master/A6-client-retries.md).
  #
  # This is the untyped building block used by the typed call classes
  # (`UnaryCall`, `ServerStreamingCall`, `ClientStreamingCall`,
  # `BidiStreamingCall`).
  class ClientCall
    # Resolved per-call settings.
    record Settings,
      compression : String? = nil,
      max_receive_message_size : Int32 = DEFAULT_MAX_RECEIVE_MESSAGE_SIZE,
      max_send_message_size : Int32 = DEFAULT_MAX_SEND_MESSAGE_SIZE,
      wait_for_ready : Bool? = nil,
      call_credentials : CallCredentials? = nil

    # Header carrying the number of preceding attempts (gRFC A6).
    PREVIOUS_ATTEMPTS_HEADER = "grpc-previous-rpc-attempts"
    PUSHBACK_HEADER          = "grpc-retry-pushback-ms"
    # Bound on consecutive attempts that fail before their stream was
    # created, to never spin on a broken connection.
    MAX_UNSENT_ATTEMPTS = 100

    # How an attempt ended before the call committed to it.
    private struct AttemptResult
      # Response headers (the attempt is committed), else nil.
      getter headers : Array({String, String})?
      getter status : Status
      getter trailers : Metadata
      # Pushback in milliseconds; negative means "do not retry".
      getter pushback : Int64?
      # Whether the server refused the stream before processing it.
      getter? refused : Bool
      # Whether the status comes from a trailers-only response.
      getter? trailers_only : Bool

      def initialize(@headers, @status, @trailers, @pushback = nil, @refused = false, @trailers_only = false)
      end
    end

    # One attempt of the call.
    private class Attempt
      getter stream : HTTP2::Stream
      property result : AttemptResult? = nil
      property messages_sent = 0

      def initialize(@stream : HTTP2::Stream)
      end
    end

    getter method_path : String
    getter deadline : Time::Instant?

    @channel : Channel
    @metadata : Metadata
    @compression : String?
    @max_receive_message_size : Int32
    @max_send_message_size : Int32
    @wait_for_ready : Bool
    @call_credentials : CallCredentials?
    @retry_policy : ServiceConfig::RetryPolicy? = nil
    @hedging_policy : ServiceConfig::HedgingPolicy? = nil
    @throttle : RetryThrottle? = nil

    # Call state, protected by @mutex.
    @mutex = Mutex.new
    @attempts = [] of Attempt
    @committed : Attempt? = nil
    @commit_pending = false
    @response_attempt : Attempt? = nil
    @final_attempt : Attempt? = nil
    @attempts_started = 0
    @total_attempts = 0
    @retries = 0
    @transparent_retry_used = false
    @transparent_pending = false
    @next_attempt_at : Time::Instant? = nil
    @hedging_stopped = false
    @last_failure : {Status, Metadata}? = nil
    @buffer = [] of Bytes
    @buffer_bytes = 0_i64
    @send_closed = false
    @deadline_exceeded = false
    @cancelled = false
    @response_headers : Metadata? = nil
    @response_encoding : String? = nil
    @status : Status? = nil
    @trailers : Metadata? = nil
    # Whether the channel was told that the call ended (for idleness).
    @activity_released = Atomic(Bool).new(false)

    @done = ::Channel(Nil).new
    @wakeup = ::Channel(Nil).new(1)
    # Serializes sends and the replay of buffered messages.
    @send_mutex = Mutex.new
    # Only one fiber drives attempts at a time.
    @drive_mutex = Mutex.new

    # Starts a call: waits for name resolution, applies the method's
    # service config and starts the first attempt. Raises `GRPC::Error` if
    # the call cannot be started.
    def self.start(channel : Channel, method_path : String, metadata : Metadata, deadline : Time::Instant?,
                   settings : Settings) : ClientCall
      call = new(channel, method_path, metadata, deadline, settings)
      call.start_call
      call
    end

    # :ditto:
    def self.start(channel : Channel, method_path : String, metadata : Metadata, deadline : Time::Instant?,
                   compression : String?, max_receive_message_size : Int32) : ClientCall
      start(channel, method_path, metadata, deadline,
        Settings.new(compression: compression, max_receive_message_size: max_receive_message_size))
    end

    # :nodoc:
    def initialize(@channel : Channel, @method_path : String, @metadata : Metadata, @deadline : Time::Instant?,
                   settings : Settings)
      compression = settings.compression
      @compression = compression == Compression::IDENTITY ? nil : compression
      @max_receive_message_size = settings.max_receive_message_size
      @max_send_message_size = settings.max_send_message_size
      @wait_for_ready = settings.wait_for_ready || false
      @requested_wait_for_ready = settings.wait_for_ready
      @call_credentials = settings.call_credentials
      @rpc_info = Stats::RPCInfo.new(@method_path, client: true, peer: @channel.authority)
    end

    getter rpc_info : Stats::RPCInfo
    @messages_sent = 0
    @messages_received = 0
    @in_header_emitted = false

    @requested_wait_for_ready : Bool?

    protected def start_call : Nil
      @channel.call_metrics.record_start
      emit(Stats::Begin.new(@rpc_info.started_at, @requested_wait_for_ready == true))
      @channel.call_started
      if (deadline = @deadline) && deadline <= Time.instant
        fail_start(Status.new(StatusCode::DeadlineExceeded, "Deadline exceeded before the call started"))
      end
      config = begin
        @channel.await_service_config(@requested_wait_for_ready == true, @deadline, @done)
      rescue e : Error
        fail_start(e.status)
      end
      apply_method_config(config.try(&.method_config(@method_path)))
      start_deadline_timer
      @mutex.synchronize { @next_attempt_at = Time.instant }
      drive(until_started: true)
      if status = @mutex.synchronize { @status }
        raise Error.new(status, @mutex.synchronize { @trailers })
      end
      emit(Stats::OutHeader.new(@metadata, @compression))
    end

    private def fail_start(status : Status) : NoReturn
      complete(status, Metadata.new)
      raise Error.new(status)
    end

    private def apply_method_config(config : ServiceConfig::MethodConfig?) : Nil
      if config
        if timeout = config.timeout
          limit = Time.instant + timeout
          @deadline = limit if (deadline = @deadline).nil? || limit < deadline
        end
        @wait_for_ready = config.wait_for_ready || false if @requested_wait_for_ready.nil?
        if max = config.max_response_message_bytes
          @max_receive_message_size = Math.min(@max_receive_message_size.to_i64, max).to_i32
        end
        if max = config.max_request_message_bytes
          @max_send_message_size = Math.min(@max_send_message_size.to_i64, max).to_i32
        end
      end
      return unless @channel.retries_enabled?
      @retry_policy = config.try(&.retry_policy)
      @hedging_policy = config.try(&.hedging_policy)
      @throttle = @channel.retry_throttle
    end

    private def start_deadline_timer : Nil
      return unless deadline = @deadline
      spawn(name: "grpc-client-deadline") do
        select
        when @done.receive?
        when timeout(Math.max(deadline - Time.instant, Time::Span.zero))
          expired = @mutex.synchronize do
            @deadline_exceeded = true unless @status
            @deadline_exceeded
          end
          if expired
            reset_attempts(HTTP2::ErrorCode::CANCEL)
            complete(Status.new(StatusCode::DeadlineExceeded, "Deadline exceeded"), Metadata.new)
          end
        end
      end
    end

    # --- Sending ---

    # Sends a request message. If *end_stream* is true the request side is
    # closed afterwards.
    def send_message(message : Protobuf::Message, end_stream : Bool = false) : Nil
      check_local_termination!
      bytes = message.to_protobuf
      if bytes.size > @max_send_message_size
        status = Status.new(StatusCode::ResourceExhausted,
          "Sent message larger than max (#{bytes.size} vs. #{@max_send_message_size})")
        reset_attempts(HTTP2::ErrorCode::CANCEL)
        complete(status, Metadata.new)
        raise Error.new(status)
      end
      frame = Framing.encode(bytes, @compression)
      send_frame(frame, end_stream)
      @messages_sent += 1
      connection_metrics.try &.record_message_sent
      emit(Stats::OutPayload.new(message, bytes.size, frame.size, !@compression.nil?))
    end

    # Closes the request side of the call.
    def close_send : Nil
      check_local_termination!
      failure = nil
      @send_mutex.synchronize do
        committed = nil
        targets = @mutex.synchronize do
          @send_closed = true
          (committed = @committed) ? [committed] : @attempts.dup
        end
        targets.each do |attempt|
          attempt.stream.close_send
        rescue e : HTTP2::Error | IO::Error
          failure = {attempt, e} if attempt.same?(committed)
        end
      end
      if failure
        handle_send_failure(*failure)
      end
    end

    private def send_frame(frame : Bytes, end_stream : Bool) : Nil
      failure = nil
      @send_mutex.synchronize do
        committed = @mutex.synchronize { @committed }
        if committed.nil? && !buffer(frame)
          # The buffer overflows: commit. Without an attempt in flight the
          # frame is kept for the replay to the next (committed) attempt.
          committed = commit_for_buffer
          buffer(frame, force: true) unless committed
        end

        if committed
          begin
            committed.stream.send_data(frame, end_stream)
            @mutex.synchronize { @send_closed = true } if end_stream
          rescue e : HTTP2::Error | IO::Error
            failure = {committed, e}
          end
        else
          attempts = @mutex.synchronize do
            @send_closed = true if end_stream
            @attempts.dup
          end
          attempts.each do |attempt|
            attempt.stream.send_data(frame, end_stream)
            attempt.messages_sent += 1
          rescue HTTP2::Error | IO::Error
            # The attempt failed; its result is handled by the driver.
          end
        end
      end
      if failure
        handle_send_failure(*failure)
      end
    end

    # Adds *frame* to the retry buffer. Returns `false` if a buffer limit
    # would be exceeded (the call then commits).
    private def buffer(frame : Bytes, force : Bool = false) : Bool
      @mutex.synchronize do
        if force
          @channel.force_reserve_retry_buffer(frame.size)
        else
          return false if @buffer_bytes + frame.size > @channel.per_rpc_buffer_size
          return false unless @channel.reserve_retry_buffer(frame.size)
        end
        @buffer << frame
        @buffer_bytes += frame.size
        true
      end
    end

    # Commits when the retry buffer overflows: to the attempt that sent the
    # most messages, cancelling the others. Without an attempt in flight
    # the next attempt is committed (the frame is buffered for its replay).
    private def commit_for_buffer : Attempt?
      cancelled = [] of Attempt
      committed = @mutex.synchronize do
        if winner = @attempts.max_by?(&.messages_sent)
          cancelled = @attempts.reject(&.same?(winner))
          commit_locked(winner)
          winner
        else
          @commit_pending = true
          nil
        end
      end
      cancelled.each { |attempt| attempt.stream.reset(HTTP2::ErrorCode::CANCEL) rescue nil }
      committed
    end

    # Commits the call to *attempt*: no further attempts are made and the
    # buffer is released. Lock held.
    private def commit_locked(attempt : Attempt) : Nil
      @committed = attempt
      @attempts = [attempt]
      @commit_pending = false
      @transparent_pending = false
      @next_attempt_at = nil
      release_buffer_locked
    end

    private def release_buffer_locked : Nil
      @channel.release_retry_buffer(@buffer_bytes)
      @buffer_bytes = 0
      @buffer = [] of Bytes
    end

    # --- Attempts ---

    # Runs the retry logic until the call committed to an attempt that
    # received response headers, or completed. With *until_started*, stops
    # as soon as an attempt is in flight.
    private def drive(until_started : Bool = false) : Nil
      @drive_mutex.synchronize do
        loop do
          break if resolved?(until_started)
          process_results
          break if resolved?(until_started)
          next if launch_due_attempt
          finish_if_exhausted
          break if resolved?(until_started)
          wait_for_event
        end
      end
    end

    private def resolved?(until_started : Bool) : Bool
      @mutex.synchronize do
        !@status.nil? || !@response_attempt.nil? || (until_started && !@attempts.empty?)
      end
    end

    # Handles the results of finished attempts.
    private def process_results : Nil
      finished = @mutex.synchronize do
        done = @attempts.select(&.result)
        @attempts.reject!(&.result) unless done.empty?
        done
      end
      finished.each do |attempt|
        result = attempt.result.not_nil!
        if headers = result.headers
          commit_response(attempt, headers)
          return
        end
        attempt_failed(attempt, result)
        return if @mutex.synchronize { @status }
      end
    end

    private def commit_response(attempt : Attempt, headers : Array({String, String})) : Nil
      others = @mutex.synchronize do
        losers = @attempts.reject(&.same?(attempt))
        commit_locked(attempt)
        @response_attempt = attempt
        @response_encoding = headers.find { |(name, _)| name == "grpc-encoding" }.try(&.[1])
        @response_headers = Metadata.from_fields(headers)
        losers
      end
      others.each { |other| other.stream.reset(HTTP2::ErrorCode::CANCEL) rescue nil }
      # A call whose response is abandoned unread still ends with its stream.
      attempt.stream.on_close { release_activity }
    end

    # Decides what to do after *attempt* failed with *result* before the
    # call committed to response headers.
    private def attempt_failed(attempt : Attempt, result : AttemptResult) : Nil
      status = result.status
      @mutex.synchronize { @last_failure = {status, result.trailers} }
      committed = @mutex.synchronize { @committed }

      if status.ok? || attempt.same?(committed) || local_termination?
        finish_attempt(attempt, result)
        return
      end

      # Refused by the server before processing: retry once transparently.
      if result.refused? && @channel.retries_enabled? && !@mutex.synchronize { @transparent_retry_used }
        @mutex.synchronize do
          @transparent_retry_used = true
          @transparent_pending = true
        end
        return
      end

      if policy = @hedging_policy
        hedge_failed(attempt, result, policy)
      elsif policy = @retry_policy
        retry_failed(attempt, result, policy)
      else
        finish_attempt(attempt, result)
      end
    end

    private def retry_failed(attempt : Attempt, result : AttemptResult, policy : ServiceConfig::RetryPolicy) : Nil
      unless policy.retryable_status_codes.includes?(result.status.code)
        finish_attempt(attempt, result)
        return
      end
      @throttle.try &.record_failure
      pushback = result.pushback
      if (pushback && pushback < 0) || @mutex.synchronize { @attempts_started } >= policy.max_attempts ||
         throttled?
        finish_attempt(attempt, result)
        return
      end
      delay = if pushback
                @mutex.synchronize { @retries = 0 }
                pushback.milliseconds
              else
                policy.backoff(@mutex.synchronize { @retries += 1 })
              end
      if (deadline = @deadline) && Time.instant + delay >= deadline
        # The retry could not start before the deadline.
        finish_attempt(attempt, result)
        return
      end
      @mutex.synchronize { @next_attempt_at = Time.instant + delay }
    end

    private def hedge_failed(attempt : Attempt, result : AttemptResult, policy : ServiceConfig::HedgingPolicy) : Nil
      unless policy.non_fatal_status_codes.includes?(result.status.code)
        # A fatal status ends the call; cancel the other attempts.
        finish_attempt(attempt, result)
        return
      end
      @throttle.try &.record_failure
      pushback = result.pushback
      @mutex.synchronize do
        if pushback && pushback < 0
          @hedging_stopped = true
          @next_attempt_at = nil
        elsif !@hedging_stopped && @attempts_started < policy.max_attempts && !throttled?
          @next_attempt_at = Time.instant + (pushback || 0).milliseconds
        end
      end
      # finish_if_exhausted ends the call once nothing is left in flight.
    end

    # Completes the call with the result of *attempt*, cancelling the
    # others.
    private def finish_attempt(attempt : Attempt, result : AttemptResult) : Nil
      others = @mutex.synchronize do
        @final_attempt = attempt
        losers = @attempts.reject(&.same?(attempt))
        @attempts.clear
        @next_attempt_at = nil
        losers
      end
      others.each { |other| other.stream.reset(HTTP2::ErrorCode::CANCEL) rescue nil }
      unless attempt.stream.closed?
        attempt.stream.reset(result.trailers_only? ? HTTP2::ErrorCode::NO_ERROR : HTTP2::ErrorCode::CANCEL) rescue nil
      end
      complete(result.status, result.trailers)
    end

    # Completes the call with the last failure once no attempt is in
    # flight or scheduled.
    private def finish_if_exhausted : Nil
      failure = @mutex.synchronize do
        return unless @status.nil? && @attempts.empty? && @next_attempt_at.nil? && !@transparent_pending
        @last_failure
      end
      status, trailers = failure || {Status.new(StatusCode::Internal, "No attempt was made"), Metadata.new}
      complete(status, trailers)
    end

    # Starts the next attempt if one is due. Returns `true` if it tried.
    private def launch_due_attempt : Bool
      transparent = false
      due = @mutex.synchronize do
        if @transparent_pending
          @transparent_pending = false
          transparent = true
        elsif (at = @next_attempt_at) && at <= Time.instant
          @next_attempt_at = nil
          true
        else
          false
        end
      end
      return false unless due || transparent
      launch_attempt(transparent)
      true
    end

    private def wait_for_event : Nil
      at, single = @mutex.synchronize do
        {@next_attempt_at, (@attempts.first if @attempts.size == 1 && @hedging_policy.nil?)}
      end
      if single && at.nil?
        # Cancellation and deadlines reset the stream, which wakes this up.
        result = await_result(single.stream)
        @mutex.synchronize { single.result = result }
        return
      end
      if at
        select
        when @wakeup.receive
        when @done.receive?
        when timeout(Math.max(at - Time.instant, Time::Span.zero))
        end
      else
        select
        when @wakeup.receive
        when @done.receive?
        end
      end
    end

    # Starts an attempt: picks a connection, opens a stream, replays the
    # buffered messages and spawns a fiber waiting for its response
    # headers. Failures before the stream exists become attempt results.
    private def launch_attempt(transparent : Bool) : Nil
      unless transparent
        @mutex.synchronize do
          @attempts_started += 1
          schedule_next_hedge_locked
        end
      end

      unsent = 0
      loop do
        return if local_termination?
        previous = @mutex.synchronize { @total_attempts }
        stream = begin
          open_attempt_stream(previous)
        rescue e : PickError
          if e.drop?
            complete(e.status, Metadata.new)
          else
            record_unstarted_failure(e.status)
          end
          return
        rescue e : Error
          complete(local_status || e.status, Metadata.new)
          return
        rescue e : HTTP2::RefusedStreamError | HTTP2::ConnectionClosedError | IO::Error | Socket::Error
          # The stream never left the client: retry transparently.
          unsent += 1
          if unsent >= MAX_UNSENT_ATTEMPTS
            record_unstarted_failure(Status.new(StatusCode::Unavailable, "Failed to start call: #{e.message}"))
            return
          end
          Fiber.yield
          next
        rescue e : HTTP2::Error
          record_unstarted_failure(Status.new(StatusCode::Unavailable, "Failed to start call: #{e.message}"))
          return
        end
        @mutex.synchronize { @total_attempts += 1 }
        attempt = Attempt.new(stream)
        register_attempt(attempt)
        return
      end
    end

    # Hedging: the next hedged attempt is due `hedgingDelay` after this one.
    private def schedule_next_hedge_locked : Nil
      return unless policy = @hedging_policy
      return if @hedging_stopped || @attempts_started >= policy.max_attempts
      return if throttled?
      @next_attempt_at = Time.instant + policy.hedging_delay
    end

    # Whether retry throttling currently forbids retries and hedges.
    private def throttled? : Bool
      (throttle = @throttle) ? !throttle.allows_retry? : false
    end

    # An attempt failed before a stream was opened (e.g. the channel is in
    # TRANSIENT_FAILURE): handled like an attempt failing with *status*.
    private def record_unstarted_failure(status : Status) : Nil
      attempt_failed_without_stream(AttemptResult.new(nil, status, Metadata.new))
    end

    private def attempt_failed_without_stream(result : AttemptResult) : Nil
      @mutex.synchronize { @last_failure = {result.status, result.trailers} }
      committed = @mutex.synchronize { @commit_pending || !@committed.nil? }
      if committed || local_termination?
        complete(local_status || result.status, result.trailers)
      elsif policy = @hedging_policy
        unless policy.non_fatal_status_codes.includes?(result.status.code)
          finish_unstarted(result)
          return
        end
        @throttle.try &.record_failure
        @mutex.synchronize do
          if !@hedging_stopped && @attempts_started < policy.max_attempts && @next_attempt_at.nil? && !throttled?
            @next_attempt_at = Time.instant + policy.hedging_delay
          end
        end
      elsif policy = @retry_policy
        unless policy.retryable_status_codes.includes?(result.status.code)
          finish_unstarted(result)
          return
        end
        @throttle.try &.record_failure
        if @mutex.synchronize { @attempts_started } >= policy.max_attempts || throttled?
          finish_unstarted(result)
          return
        end
        delay = policy.backoff(@mutex.synchronize { @retries += 1 })
        if (deadline = @deadline) && Time.instant + delay >= deadline
          finish_unstarted(result)
          return
        end
        @mutex.synchronize { @next_attempt_at = Time.instant + delay }
      else
        complete(result.status, result.trailers)
      end
    end

    private def finish_unstarted(result : AttemptResult) : Nil
      others = @mutex.synchronize do
        losers = @attempts.dup
        @attempts.clear
        @next_attempt_at = nil
        losers
      end
      others.each { |other| other.stream.reset(HTTP2::ErrorCode::CANCEL) rescue nil }
      complete(result.status, result.trailers)
    end

    # Picks a connection and opens the attempt's stream.
    private def open_attempt_stream(previous_attempts : Int32) : HTTP2::Stream
      info = LoadBalancer::PickInfo.new(@method_path, @metadata)
      connection = @channel.pick_connection(info, @wait_for_ready, @deadline, @done)
      fields = request_fields(previous_attempts)
      if deadline = @deadline
        open_stream(connection, fields, deadline)
      else
        connection.open_stream(fields)
      end
    end

    private def request_fields(previous_attempts : Int32) : Array({String, String})
      fields = [
        {":method", "POST"},
        {":scheme", @channel.scheme},
        {":path", @method_path},
        {":authority", @channel.authority},
        {"content-type", "application/grpc"},
        {"te", "trailers"},
        {"user-agent", @channel.user_agent},
        {"grpc-accept-encoding", Compression::ACCEPT_ENCODING},
      ]
      if deadline = @deadline
        remaining = deadline - Time.instant
        raise Error.new(StatusCode::DeadlineExceeded, "Deadline exceeded") if remaining <= Time::Span.zero
        fields << {"grpc-timeout", Timeout.encode(remaining)}
      end
      fields << {"grpc-encoding", @compression.not_nil!} if @compression
      fields << {PREVIOUS_ATTEMPTS_HEADER, previous_attempts.to_s} if previous_attempts > 0
      @metadata.to_fields(fields)
      call_credentials_metadata.to_fields(fields)
      fields
    end

    # Metadata of the channel's and the call's credentials.
    private def call_credentials_metadata : Metadata
      metadata = Metadata.new
      channel_credentials = @channel.credentials.call_credentials
      return metadata unless channel_credentials || @call_credentials
      credentials = [channel_credentials, @call_credentials].compact
      context = CallCredentials::Context.new(@method_path, @channel.authority, @channel.secure?)
      credentials.each { |creds| CallCredentials.apply(creds, context, metadata) }
      metadata
    end

    # Opening a stream may block (waiting for the server's
    # MAX_CONCURRENT_STREAMS limit); don't wait beyond the deadline.
    private def open_stream(connection : HTTP2::Connection, fields : Array({String, String}), deadline : Time::Instant) : HTTP2::Stream
      result = ::Channel(HTTP2::Stream | Exception).new(1)
      spawn(name: "grpc-open-stream") do
        result.send(connection.open_stream(fields))
      rescue e
        result.send(e)
      end
      select
      when opened = result.receive
        raise opened if opened.is_a?(Exception)
        opened
      when timeout(Math.max(deadline - Time.instant, Time::Span.zero))
        # Reset the stream if it is opened after all.
        spawn(name: "grpc-open-stream-abandoned") do
          late = result.receive
          late.reset(HTTP2::ErrorCode::CANCEL) if late.is_a?(HTTP2::Stream)
        end
        raise Error.new(StatusCode::DeadlineExceeded, "Deadline exceeded while starting the call")
      end
    end

    # Makes *attempt* receive future sends (after replaying the buffer) and
    # waits for its response headers in a new fiber.
    private def register_attempt(attempt : Attempt) : Nil
      @send_mutex.synchronize do
        buffered, closed = @mutex.synchronize { {@buffer.dup, @send_closed} }
        buffered.each_with_index do |frame, i|
          attempt.stream.send_data(frame, closed && i == buffered.size - 1)
          attempt.messages_sent += 1
        rescue HTTP2::Error | IO::Error
          break
        end
        if closed && buffered.empty?
          attempt.stream.close_send rescue nil
        end
        cancel_now = @mutex.synchronize do
          if @status || @cancelled || @deadline_exceeded
            true
          else
            @attempts << attempt
            if @commit_pending || !@channel.retries_enabled?
              commit_locked(attempt)
            end
            false
          end
        end
        if cancel_now
          attempt.stream.reset(HTTP2::ErrorCode::CANCEL) rescue nil
          return
        end
      end
      # Concurrent (hedged) attempts are watched by their own fibers;
      # otherwise the driver waits for the single attempt directly.
      watch_attempt(attempt) if @hedging_policy
    end

    private def watch_attempt(attempt : Attempt) : Nil
      spawn(name: "grpc-attempt") do
        result = await_result(attempt.stream)
        @mutex.synchronize { attempt.result = result }
        select
        when @wakeup.send(nil)
        else
        end
      end
    end

    # Waits for the response headers of an attempt and classifies them.
    private def await_result(stream : HTTP2::Stream) : AttemptResult
      fields = begin
        stream.headers
      rescue e : HTTP2::Error | IO::Error
        refused = e.is_a?(HTTP2::RefusedStreamError) ||
                  (e.is_a?(HTTP2::StreamResetError) && e.remote? && e.code.refused_stream?)
        return AttemptResult.new(nil, status_for_stream_error(e), Metadata.new, refused: refused)
      end

      http_status = fields.find { |(name, _)| name == ":status" }.try(&.[1].to_i?) || 0
      grpc_status = fields.find { |(name, _)| name == "grpc-status" }
      content_type = fields.find { |(name, _)| name == "content-type" }.try(&.[1])

      if http_status != 200 && grpc_status.nil?
        code = StatusCode.from_http_status(http_status)
        return AttemptResult.new(nil, Status.new(code, "Unexpected HTTP status #{http_status}"), Metadata.from_fields(fields))
      end
      unless content_type && content_type.starts_with?("application/grpc")
        return AttemptResult.new(nil, Status.new(StatusCode::Unknown, "Unexpected content-type #{content_type.inspect}"),
          Metadata.from_fields(fields))
      end
      if grpc_status
        pushback = fields.find { |(name, _)| name == PUSHBACK_HEADER }.try { |(_, value)| ClientCall.parse_pushback(value) }
        return AttemptResult.new(nil, parse_status(fields), Metadata.from_fields(fields), pushback, trailers_only: true)
      end
      AttemptResult.new(fields, Status.ok, Metadata.new)
    end

    # Parses `grpc-retry-pushback-ms`: a non-negative delay, or -1 for
    # negative or malformed values (do not retry).
    def self.parse_pushback(value : String) : Int64
      return -1_i64 unless value.matches?(/\A(0|[1-9][0-9]*)\z/)
      value.to_i32?.try(&.to_i64) || -1_i64
    end

    # --- Receiving ---

    # Cancels the call. Pending and future operations raise
    # `GRPC::Error(Cancelled)`.
    def cancel : Nil
      @mutex.synchronize do
        return if @status
        @cancelled = true
      end
      reset_attempts(HTTP2::ErrorCode::CANCEL)
      complete(Status.new(StatusCode::Cancelled, "Call cancelled by client"), Metadata.new)
    end

    # The HTTP/2 stream of the attempt the call committed to (or of the
    # attempt that ended it). Waits until known.
    def stream : HTTP2::Stream
      drive
      attempt = @mutex.synchronize { @response_attempt || @final_attempt || @committed }
      return attempt.stream if attempt
      raise Error.new(@mutex.synchronize { @status } || Status.new(StatusCode::Internal, "No stream"))
    end

    # Waits for and returns the response headers (initial metadata).
    def response_headers : Metadata
      receive_headers
      @mutex.synchronize { @response_headers } || Metadata.new
    end

    # Receives the next response message, or `nil` once the server finished
    # (the status is then available from `#status`).
    def receive_message(type : T.class) : T? forall T
      receive_headers
      attempt = @mutex.synchronize do
        return nil if @status
        @response_attempt.not_nil!
      end
      stream = attempt.stream

      bytes = begin
        Framing.read(stream.body, @response_encoding, @max_receive_message_size)
      rescue e : Error
        # A response compressed with an encoding we do not support is the
        # server's fault: report INTERNAL rather than UNIMPLEMENTED.
        e = Error.new(StatusCode::Internal, e.status.message) if e.code.unimplemented?
        stream.reset(HTTP2::ErrorCode::CANCEL)
        complete(e.status, Metadata.new)
        raise e
      rescue e : HTTP2::Error | IO::Error
        fail_from_stream_error(stream, e)
      end

      unless bytes
        receive_trailers(stream)
        # Stop the server from waiting for more requests if we were still
        # sending.
        stream.reset(HTTP2::ErrorCode::NO_ERROR) unless stream.closed?
        return nil
      end

      begin
        message = T.from_protobuf(bytes)
        @messages_received += 1
        stream.connection.metrics.record_message_received
        emit(Stats::InPayload.new(message, bytes.size, bytes.size + Framing::HEADER_SIZE, !@response_encoding.nil?))
        message
      rescue e : Protobuf::DecodeError
        stream.reset(HTTP2::ErrorCode::CANCEL)
        error = Error.new(StatusCode::Internal, "Failed to parse response message: #{e.message}")
        complete(error.status, Metadata.new)
        raise error
      end
    end

    # The final status. Waits for the call to complete, discarding any
    # unread response messages.
    def status : Status
      loop do
        if status = @mutex.synchronize { @status }
          return status
        end
        begin
          receive_headers
          if attempt = @mutex.synchronize { @response_attempt unless @status }
            drain(attempt.stream)
          end
        rescue Error
        end
      end
    end

    # The trailing metadata. Waits for the call to complete.
    def trailers : Metadata
      status
      @mutex.synchronize { @trailers } || Metadata.new
    end

    # Raises `GRPC::Error` if the call completed with a non-OK status.
    def check_status! : Nil
      status = self.status
      raise Error.new(status, trailers) unless status.ok?
    end

    def finished? : Bool
      @mutex.synchronize { !@status.nil? }
    end

    # The number of attempts made so far (including transparent retries).
    def attempts : Int32
      @mutex.synchronize { @total_attempts }
    end

    # Waits until the call committed to response headers or completed.
    # Raises `GRPC::Error` if the call ended without response headers
    # because of a local condition (deadline or cancellation).
    private def receive_headers : Nil
      drive
      check_local_termination!
      emit_in_header
    end

    private def emit_in_header : Nil
      return if stats.empty?
      headers, encoding = @mutex.synchronize do
        return if @in_header_emitted || @response_headers.nil?
        @in_header_emitted = true
        {@response_headers.not_nil!, @response_encoding}
      end
      emit(Stats::InHeader.new(headers, encoding))
    end

    private def drain(stream : HTTP2::Stream) : Nil
      loop do
        bytes = Framing.read(stream.body, @response_encoding, Int32::MAX)
        break unless bytes
      end
      receive_trailers(stream)
    rescue e : HTTP2::Error | IO::Error
      fail_from_stream_error(stream, e)
    end

    private def receive_trailers(stream : HTTP2::Stream) : Nil
      fields = stream.wait_end_stream
      if fields
        status = parse_status(fields)
        record_committed_outcome(status)
        complete(status, Metadata.from_fields(fields))
      elsif error = stream.error
        fail_from_stream_error(stream, error)
      else
        complete(Status.new(StatusCode::Internal, "Server closed the stream without sending trailers"), Metadata.new)
      end
    end

    # Retry throttling counts failures of committed calls too.
    private def record_committed_outcome(status : Status) : Nil
      return unless throttle = @throttle
      return if status.ok?
      code = status.code
      if @retry_policy.try(&.retryable_status_codes.includes?(code)) ||
         @hedging_policy.try(&.non_fatal_status_codes.includes?(code))
        throttle.record_failure
      end
    end

    private def parse_status(fields : Array({String, String})) : Status
      code = StatusCode::Unknown
      message = ""
      details = nil
      found = false
      fields.each do |(name, value)|
        case name
        when "grpc-status"
          found = true
          code = value.to_i?.try { |v| StatusCode.from_value?(v) } || StatusCode::Unknown
        when "grpc-message"
          message = Status.decode_message(value)
        when "grpc-status-details-bin"
          details = Base64.decode(value) rescue nil
        end
      end
      return Status.new(StatusCode::Internal, "Missing grpc-status in trailers") unless found
      Status.new(code, message, details)
    end

    # The server may complete the call (e.g. with an error) while we are
    # still sending. Report its status if it failed; once the server has
    # successfully completed the call further messages are discarded.
    private def handle_send_failure(attempt : Attempt, error : Exception) : Nil
      check_local_termination!
      receive_headers
      stream = attempt.stream
      if stream.end_stream_received? && (fields = stream.trailers)
        # The server completed the call. Take the status from its trailers
        # without consuming response messages that were not read yet (e.g.
        # the response of a client streaming call).
        status = parse_status(fields)
        return if status.ok?
        complete(status, Metadata.from_fields(fields))
      end
      status = self.status
      raise Error.new(status, trailers) unless status.ok?
    end

    private def local_termination? : Bool
      @mutex.synchronize { @deadline_exceeded || @cancelled }
    end

    private def local_status : Status?
      @mutex.synchronize do
        if @deadline_exceeded
          Status.new(StatusCode::DeadlineExceeded, "Deadline exceeded")
        elsif @cancelled
          Status.new(StatusCode::Cancelled, "Call cancelled by client")
        end
      end
    end

    private def check_local_termination! : Nil
      return unless status = local_status
      complete(status, Metadata.new)
      raise Error.new(@mutex.synchronize { @status } || status)
    end

    private def fail_from_stream_error(stream : HTTP2::Stream, error : Exception) : NoReturn
      check_local_termination!
      status = status_for_stream_error(error)
      record_committed_outcome(status)
      fail_with(stream, status, Metadata.new)
    end

    private def status_for_stream_error(error : Exception) : Status
      if status = local_status
        return status
      end
      case error
      when HTTP2::StreamResetError
        Status.new(code_for_reset(error.code), "Stream reset by server: #{error.code}")
      when HTTP2::RefusedStreamError
        Status.new(StatusCode::Unavailable, error.message || "Stream refused")
      when HTTP2::ConnectionClosedError
        Status.new(StatusCode::Unavailable, error.message || "Connection closed")
      else
        Status.new(StatusCode::Unavailable, error.message || error.class.name)
      end
    end

    private def fail_with(stream : HTTP2::Stream, status : Status, metadata : Metadata) : NoReturn
      stream.reset(HTTP2::ErrorCode::CANCEL) unless stream.closed?
      complete(status, metadata)
      final = @mutex.synchronize { {@status, @trailers} }
      raise Error.new(final[0] || status, final[1] || metadata)
    end

    private def reset_attempts(code : HTTP2::ErrorCode) : Nil
      attempts = @mutex.synchronize do
        list = @attempts.dup
        [@committed, @response_attempt].each { |a| list << a if a && !list.includes?(a) }
        list
      end
      attempts.each { |attempt| attempt.stream.reset(code) rescue nil }
    end

    private def complete(status : Status, trailers : Metadata) : Nil
      @mutex.synchronize do
        return if @status
        if @deadline_exceeded
          status = Status.new(StatusCode::DeadlineExceeded, "Deadline exceeded")
        end
        @status = status
        @trailers = trailers
        @next_attempt_at = nil
        release_buffer_locked
      end
      @done.close
      @channel.call_metrics.record_end(status.ok?)
      @throttle.try &.record_success if status.ok?
      release_activity
      unless stats.empty?
        emit_in_header
        emit(Stats::Trailer.new(trailers))
        emit(Stats::End.new(status, Time.utc - @rpc_info.started_at, @messages_sent, @messages_received))
      end
    end

    private def connection_metrics : HTTP2::ConnectionMetrics?
      @mutex.synchronize { @committed || @attempts.last? }.try(&.stream.connection.metrics)
    end

    private def stats : Stats::Dispatcher
      @channel.stats
    end

    private def emit(event : Stats::Event) : Nil
      dispatcher = @channel.stats
      dispatcher.emit(@rpc_info, event) unless dispatcher.empty?
    end

    private def release_activity : Nil
      @channel.call_finished unless @activity_released.swap(true)
    end

    # Maps RST_STREAM error codes to status codes
    # (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md#errors).
    private def code_for_reset(code : HTTP2::ErrorCode) : StatusCode
      case code
      when .refused_stream?      then StatusCode::Unavailable
      when .cancel?              then StatusCode::Cancelled
      when .enhance_your_calm?   then StatusCode::ResourceExhausted
      when .inadequate_security? then StatusCode::PermissionDenied
      else                            StatusCode::Internal
      end
    end
  end

  # A unary call that gives access to the response metadata in addition to
  # the response message.
  #
  # ```
  # call = client.say_hello_call(request)
  # call.response # => Helloworld::HelloReply
  # call.headers  # => GRPC::Metadata
  # call.trailers # => GRPC::Metadata
  # ```
  class UnaryCall(Resp)
    getter call : ClientCall
    @response : Resp? = nil

    def initialize(@call : ClientCall)
    end

    # Waits for and returns the response. Raises `GRPC::Error` if the call
    # failed.
    def response : Resp
      if response = @response
        return response
      end
      response = @call.receive_message(Resp)
      if response && @call.receive_message(Resp)
        @call.cancel
        raise Error.new(StatusCode::Internal, "Received more than one response message for a unary call")
      end
      @call.check_status!
      @response = response || raise Error.new(StatusCode::Internal, "No response message received for a unary call")
    end

    def headers : Metadata
      @call.response_headers
    end

    def trailers : Metadata
      @call.trailers
    end

    def status : Status
      @call.status
    end

    def cancel : Nil
      @call.cancel
    end
  end

  # A server streaming call. Iterate it to receive response messages; the
  # iteration raises `GRPC::Error` if the call fails.
  #
  # ```
  # client.list_features(rectangle).each do |feature|
  #   puts feature.name
  # end
  # ```
  class ServerStreamingCall(Resp)
    include Iterator(Resp)

    getter call : ClientCall

    def initialize(@call : ClientCall)
    end

    # Receives the next message, or `nil` once the call completed
    # successfully.
    def receive? : Resp?
      if message = @call.receive_message(Resp)
        return message
      end
      @call.check_status!
      nil
    end

    def next
      receive? || stop
    end

    # Response headers (initial metadata).
    def headers : Metadata
      @call.response_headers
    end

    # Trailing metadata, available once the call completed.
    def trailers : Metadata
      @call.trailers
    end

    def status : Status
      @call.status
    end

    def cancel : Nil
      @call.cancel
    end
  end

  # A client streaming call: send any number of request messages, then call
  # `#close_and_receive` to get the single response.
  class ClientStreamingCall(Req, Resp)
    getter call : ClientCall

    def initialize(@call : ClientCall)
    end

    def send(message : Req) : Nil
      @call.send_message(message)
    end

    def <<(message : Req) : self
      send(message)
      self
    end

    # Closes the request stream and waits for the response.
    def close_and_receive : Resp
      @call.close_send unless @call.finished?
      response = @call.receive_message(Resp)
      @call.check_status!
      response || raise Error.new(StatusCode::Internal, "No response message received")
    end

    # Yields, then closes the request stream and returns the response. The
    # call is cancelled if the block raises.
    def run(&) : Resp
      begin
        yield
      rescue e
        cancel
        raise e
      end
      close_and_receive
    end

    def headers : Metadata
      @call.response_headers
    end

    def trailers : Metadata
      @call.trailers
    end

    def status : Status
      @call.status
    end

    def cancel : Nil
      @call.cancel
    end
  end

  # A bidirectional streaming call. Messages can be sent and received
  # concurrently (e.g. sending from a separate fiber).
  #
  # ```
  # call = client.chat
  # spawn do
  #   messages.each { |message| call.send(message) }
  #   call.close_send
  # end
  # call.each { |reply| puts reply.text }
  # ```
  class BidiStreamingCall(Req, Resp)
    include Iterator(Resp)

    getter call : ClientCall

    def initialize(@call : ClientCall)
    end

    def send(message : Req) : Nil
      @call.send_message(message)
    end

    def <<(message : Req) : self
      send(message)
      self
    end

    # Closes the request side of the call.
    def close_send : Nil
      @call.close_send
    end

    # Receives the next message, or `nil` once the call completed
    # successfully. Raises `GRPC::Error` if the call failed.
    def receive? : Resp?
      if message = @call.receive_message(Resp)
        return message
      end
      @call.check_status!
      nil
    end

    def next
      receive? || stop
    end

    def headers : Metadata
      @call.response_headers
    end

    def trailers : Metadata
      @call.trailers
    end

    def status : Status
      @call.status
    end

    def cancel : Nil
      @call.cancel
    end
  end
end
