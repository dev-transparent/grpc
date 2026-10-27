module HTTP2
  # A rate limit: at most `count` events per `period`. Used by the flood
  # protections in `ConnectionOptions`.
  record RateLimit, count : Int32, period : Time::Span = 1.second

  # Transport level behaviour of a `Connection`: keepalive, connection
  # lifetime management and abuse protection. Accepted by `Connection`,
  # `Server` and `Client`.
  #
  # Defaults are conservative so that normal traffic is never affected; see
  # `Server.default_options` and `Client.default_options` for the defaults
  # used by each endpoint.
  #
  # ```
  # options = HTTP2::ConnectionOptions.new(
  #   keepalive_time: 30.seconds,
  #   keepalive_timeout: 10.seconds,
  #   max_connection_age: 30.minutes,
  # )
  # client = HTTP2::Client.new("localhost", 50051, options: options)
  # ```
  struct ConnectionOptions
    # --- Keepalive (sender side, gRPC A8) ---

    # Sends a PING after this much time without receiving any frame. `nil`
    # disables keepalive pings.
    property keepalive_time : Time::Span? = nil

    # Closes the connection (failing all streams with
    # `ConnectionClosedError`) when a keepalive PING is not acknowledged
    # within this time. Nothing else received from the peer counts as an
    # acknowledgement.
    property keepalive_timeout : Time::Span = 20.seconds

    # Sends keepalive pings even when no streams are active.
    property? keepalive_permit_without_calls : Bool = false

    # --- Keepalive enforcement (receiver side, gRPC A9) ---

    # The minimum interval the peer must leave between PINGs while streams
    # are active. A PING arriving earlier counts as a strike. `nil` disables
    # enforcement.
    property min_ping_interval : Time::Span? = nil

    # Accept keepalive pings when no streams are active. When `false`, PINGs
    # received without active streams more often than every two hours count
    # as strikes.
    property? permit_without_stream : Bool = false

    # The number of strikes tolerated; one more closes the connection with
    # GOAWAY(ENHANCE_YOUR_CALM, "too_many_pings"). Sending DATA or HEADERS
    # resets the strike count.
    property max_ping_strikes : Int32 = 2

    # --- Connection lifetime (gRPC A9) ---

    # Gracefully closes the connection (GOAWAY) after it has had no active
    # streams for this long.
    property max_connection_idle : Time::Span? = nil

    # Gracefully closes the connection once it is this old (plus or minus
    # `max_connection_age_jitter`).
    property max_connection_age : Time::Span? = nil

    # Fraction of `max_connection_age` randomly added or subtracted so that
    # connections created together do not all close at the same time.
    property max_connection_age_jitter : Float64 = 0.1

    # After `max_connection_age` triggered a graceful shutdown, streams get
    # this much time to complete before the connection is forcibly closed.
    # `nil` waits forever.
    property max_connection_age_grace : Time::Span? = nil

    # --- Graceful shutdown ---

    # How long to wait for the PING sent with the first GOAWAY of a
    # graceful shutdown before sending the final GOAWAY anyway.
    property shutdown_ping_timeout : Time::Span = 5.seconds

    # How long a closing connection may take to flush its final frames
    # before the transport is forcibly shut down (e.g. because the peer
    # stopped reading).
    property close_timeout : Time::Span = 1.second

    # --- Abuse protection ---

    # Closes the connection with SETTINGS_TIMEOUT if the peer does not
    # acknowledge our SETTINGS within this time. `nil` disables the timer.
    property settings_timeout : Time::Span? = 30.seconds

    # Rapid reset protection (CVE-2023-44487): the number of peer initiated
    # streams the peer may reset while we were still serving them (or that
    # we refuse) per period. The connection is closed with
    # ENHANCE_YOUR_CALM only when this is exceeded *and* such premature
    # resets make up more than half of the streams opened in the period, so
    # legitimate cancellation-heavy traffic is never affected.
    property max_peer_resets : RateLimit? = RateLimit.new(1000)

    # Maximum number of request handlers that may still be running for a
    # connection, including handlers of streams that were already reset.
    # New streams beyond it are refused (and count as resets). `nil` uses
    # four times SETTINGS_MAX_CONCURRENT_STREAMS, at least 100 (unlimited if
    # that setting is unset).
    property max_running_handlers : Int32? = nil

    # Flood limits for frames that cost us work but carry no useful payload.
    # Exceeding any of them closes the connection with ENHANCE_YOUR_CALM.
    # `nil` disables a limit.
    property max_ping_rate : RateLimit? = RateLimit.new(100)
    property max_settings_rate : RateLimit? = RateLimit.new(100)
    # DATA frames without payload or END_STREAM, and HEADERS/CONTINUATION
    # frames with an empty fragment that do not end the header block.
    property max_empty_frame_rate : RateLimit? = RateLimit.new(100)
    property max_priority_rate : RateLimit? = RateLimit.new(1000)
    property max_window_update_rate : RateLimit? = RateLimit.new(10_000)

    # Maximum number of control frames (SETTINGS/PING ACKs, RST_STREAM,
    # WINDOW_UPDATE, ...) queued for sending. A peer that keeps provoking
    # them without reading our responses gets disconnected.
    property max_queued_control_frames : Int32 = 10_000

    def initialize(*, @keepalive_time = nil, @keepalive_timeout = 20.seconds,
                   @keepalive_permit_without_calls = false,
                   @min_ping_interval = nil, @permit_without_stream = false, @max_ping_strikes = 2,
                   @max_connection_idle = nil, @max_connection_age = nil,
                   @max_connection_age_jitter = 0.1, @max_connection_age_grace = nil,
                   @shutdown_ping_timeout = 5.seconds, @close_timeout = 1.second,
                   @settings_timeout = 30.seconds,
                   @max_peer_resets = RateLimit.new(1000), @max_running_handlers = nil,
                   @max_ping_rate = RateLimit.new(100), @max_settings_rate = RateLimit.new(100),
                   @max_empty_frame_rate = RateLimit.new(100), @max_priority_rate = RateLimit.new(1000),
                   @max_window_update_rate = RateLimit.new(10_000),
                   @max_queued_control_frames = 10_000)
    end
  end

  # Counts events in fixed windows of `RateLimit#period`. Not thread safe;
  # protected by the connection lock.
  # Counts premature peer resets against the streams opened in the same
  # window (see `ConnectionOptions#max_peer_resets`).
  # :nodoc:
  class ResetTracker
    @window_start : Time::Instant
    @resets = 0
    @streams = 0

    def initialize(@limit : RateLimit)
      @window_start = Time.instant
    end

    def stream_opened(now : Time::Instant = Time.instant) : Nil
      roll(now)
      @streams += 1
    end

    # Records a premature reset; returns `false` when the connection is
    # abusive.
    def record(now : Time::Instant = Time.instant) : Bool
      roll(now)
      @resets += 1
      @resets <= @limit.count || @resets * 2 <= @streams
    end

    private def roll(now : Time::Instant) : Nil
      if now - @window_start >= @limit.period
        @window_start = now
        @resets = 0
        @streams = 0
      end
    end
  end

  class RateCounter
    @window_start : Time::Instant
    @count = 0

    def initialize(@limit : RateLimit)
      @window_start = Time.instant
    end

    # Records an event at *now*; returns `false` if the limit is exceeded.
    def record(now : Time::Instant = Time.instant) : Bool
      if now - @window_start >= @limit.period
        @window_start = now
        @count = 0
      end
      @count += 1
      @count <= @limit.count
    end
  end
end
