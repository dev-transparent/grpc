module HTTP2
  # Counters describing the activity of one connection (used for channelz).
  # All counters are updated atomically and may be read at any time.
  class ConnectionMetrics
    @@next_id = Atomic(Int64).new(0_i64)

    # Allocates a process-wide unique identifier.
    def self.next_id : Int64
      @@next_id.add(1_i64) + 1
    end

    getter streams_started = Atomic(Int64).new(0_i64)
    getter streams_succeeded = Atomic(Int64).new(0_i64)
    getter streams_failed = Atomic(Int64).new(0_i64)
    # Application-level messages; maintained by protocols built on HTTP/2
    # (gRPC counts its length-prefixed messages here).
    getter messages_sent = Atomic(Int64).new(0_i64)
    getter messages_received = Atomic(Int64).new(0_i64)
    getter keepalives_sent = Atomic(Int64).new(0_i64)
    # Unix timestamps in nanoseconds (0 when never).
    getter last_local_stream_created = Atomic(Int64).new(0_i64)
    getter last_remote_stream_created = Atomic(Int64).new(0_i64)
    getter last_message_sent = Atomic(Int64).new(0_i64)
    getter last_message_received = Atomic(Int64).new(0_i64)
    # Error code of the GOAWAY received from the peer, if any.
    property goaway_error_code : UInt32? = nil

    def record_stream_created(local : Bool) : Nil
      @streams_started.add(1)
      (local ? @last_local_stream_created : @last_remote_stream_created).set(ConnectionMetrics.now)
    end

    def record_stream_closed(success : Bool) : Nil
      (success ? @streams_succeeded : @streams_failed).add(1)
    end

    def record_message_sent : Nil
      @messages_sent.add(1)
      @last_message_sent.set(ConnectionMetrics.now)
    end

    def record_message_received : Nil
      @messages_received.add(1)
      @last_message_received.set(ConnectionMetrics.now)
    end

    # Converts a timestamp counter to a `Time`, or `nil` when never set.
    def self.time(value : Int64) : Time?
      value == 0 ? nil : Time.unix_ns(value)
    end

    protected def self.now : Int64
      Time.utc.to_unix_ns.to_i64
    end
  end
end
