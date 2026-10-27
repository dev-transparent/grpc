module GRPC
  # Observability hooks: a `StatsHandler` receives an event for every step
  # of every RPC (and connection), which is the building block for metrics,
  # tracing and logging integrations.
  #
  # ```
  # class LatencyLogger < GRPC::StatsHandler
  #   def handle(rpc : GRPC::Stats::RPCInfo, event : GRPC::Stats::Event) : Nil
  #     if event.is_a?(GRPC::Stats::End)
  #       puts "#{rpc.method_path} #{event.status.code} #{event.duration.total_milliseconds}ms"
  #     end
  #   end
  # end
  #
  # server = GRPC::Server.new(stats_handlers: [LatencyLogger.new] of GRPC::StatsHandler)
  # ```
  #
  # Handlers run synchronously on the RPC's fiber and must be fast and
  # must not raise (exceptions are logged and ignored).
  module Stats
    # Identifies one RPC across its events. Handlers that need per-RPC state
    # (e.g. a tracing span) can key it by `#id` and release it on `End`.
    class RPCInfo
      @@next_id = Atomic(UInt64).new(1_u64)

      getter id : UInt64
      getter method_path : String
      getter? client : Bool
      getter peer : String?
      getter started_at : Time

      def initialize(@method_path : String, @client : Bool, @peer : String? = nil)
        @id = @@next_id.add(1_u64)
        @started_at = Time.utc
      end

      def server? : Bool
        !@client
      end
    end

    # Base class of all RPC events.
    abstract struct Event
    end

    # The RPC started (server: request headers received; client: before the
    # request headers are sent).
    struct Begin < Event
      getter time : Time
      getter? wait_for_ready : Bool

      def initialize(@time : Time = Time.utc, @wait_for_ready : Bool = false)
      end
    end

    # Request (server) or response (client) headers received.
    struct InHeader < Event
      getter metadata : Metadata
      getter compression : String?
      getter timeout : Time::Span?

      def initialize(@metadata : Metadata, @compression : String? = nil, @timeout : Time::Span? = nil)
      end
    end

    # Headers sent.
    struct OutHeader < Event
      getter metadata : Metadata
      getter compression : String?

      def initialize(@metadata : Metadata, @compression : String? = nil)
      end
    end

    # A message was received. `length` is the serialized (uncompressed)
    # size, `wire_length` the size on the wire including the 5 byte prefix.
    struct InPayload < Event
      getter message : Protobuf::Message?
      getter length : Int32
      getter wire_length : Int32
      getter? compressed : Bool

      def initialize(@message : Protobuf::Message?, @length : Int32, @wire_length : Int32, @compressed : Bool)
      end
    end

    # A message was sent.
    struct OutPayload < Event
      getter message : Protobuf::Message?
      getter length : Int32
      getter wire_length : Int32
      getter? compressed : Bool

      def initialize(@message : Protobuf::Message?, @length : Int32, @wire_length : Int32, @compressed : Bool)
      end
    end

    # Trailers received (client) or sent (server).
    struct Trailer < Event
      getter metadata : Metadata

      def initialize(@metadata : Metadata)
      end
    end

    # The RPC completed.
    struct End < Event
      getter status : Status
      getter duration : Time::Span
      getter messages_sent : Int32
      getter messages_received : Int32

      def initialize(@status : Status, @duration : Time::Span, @messages_sent : Int32, @messages_received : Int32)
      end
    end

    # Dispatches events to a list of handlers.
    # :nodoc:
    struct Dispatcher
      getter handlers : Array(StatsHandler)

      def initialize(@handlers : Array(StatsHandler))
      end

      def empty? : Bool
        @handlers.empty?
      end

      def emit(rpc : RPCInfo, event : Event) : Nil
        @handlers.each do |handler|
          handler.handle(rpc, event)
        rescue e
          GRPC::Log.warn(exception: e) { "Stats handler #{handler.class} raised" }
        end
      end
    end
  end

  # Receives RPC events. See `GRPC::Stats`.
  abstract class StatsHandler
    abstract def handle(rpc : Stats::RPCInfo, event : Stats::Event) : Nil
  end

  # A built-in `StatsHandler` aggregating per-method counters and latency
  # histograms, suitable for exporting to a metrics system.
  #
  # ```
  # metrics = GRPC::MetricsCollector.new
  # server = GRPC::Server.new(stats_handlers: [metrics] of GRPC::StatsHandler)
  # metrics.snapshot["/helloworld.Greeter/SayHello"].completed[GRPC::StatusCode::Ok]
  # ```
  class MetricsCollector < StatsHandler
    # Upper bounds (in milliseconds) of the latency histogram buckets.
    DEFAULT_BUCKETS = [1.0, 2.5, 5.0, 10.0, 25.0, 50.0, 100.0, 250.0, 500.0, 1000.0, 2500.0, 5000.0, 10000.0]

    # Counters for one method.
    class MethodStats
      getter started : Int64 = 0
      getter completed = Hash(StatusCode, Int64).new(0_i64)
      getter messages_sent : Int64 = 0
      getter messages_received : Int64 = 0
      getter bytes_sent : Int64 = 0
      getter bytes_received : Int64 = 0
      # Count of RPCs per latency bucket; the last entry counts RPCs above
      # the largest bound.
      getter latency_buckets : Array(Int64)
      getter latency_sum : Time::Span = Time::Span.zero

      def initialize(bucket_count : Int32)
        @latency_buckets = Array(Int64).new(bucket_count + 1, 0_i64)
      end

      def in_flight : Int64
        @started - @completed.values.sum
      end

      protected def record_start : Nil
        @started += 1
      end

      protected def record_in(bytes : Int32) : Nil
        @messages_received += 1
        @bytes_received += bytes
      end

      protected def record_out(bytes : Int32) : Nil
        @messages_sent += 1
        @bytes_sent += bytes
      end

      protected def record_end(code : StatusCode, duration : Time::Span, bucket : Int32) : Nil
        @completed[code] += 1
        @latency_sum += duration
        @latency_buckets[bucket] += 1
      end

      def dup : MethodStats
        copy = MethodStats.new(@latency_buckets.size - 1)
        copy.copy_from(self)
        copy
      end

      protected def copy_from(other : MethodStats) : Nil
        @started = other.started
        @completed = other.completed.dup
        @messages_sent = other.messages_sent
        @messages_received = other.messages_received
        @bytes_sent = other.bytes_sent
        @bytes_received = other.bytes_received
        @latency_buckets = other.latency_buckets.dup
        @latency_sum = other.latency_sum
      end
    end

    getter buckets : Array(Float64)
    @methods = {} of String => MethodStats
    @mutex = Mutex.new

    def initialize(@buckets : Array(Float64) = DEFAULT_BUCKETS)
    end

    def handle(rpc : Stats::RPCInfo, event : Stats::Event) : Nil
      @mutex.synchronize do
        stats = (@methods[rpc.method_path] ||= MethodStats.new(@buckets.size))
        case event
        when Stats::Begin      then stats.record_start
        when Stats::InPayload  then stats.record_in(event.wire_length)
        when Stats::OutPayload then stats.record_out(event.wire_length)
        when Stats::End
          millis = event.duration.total_milliseconds
          bucket = @buckets.index { |bound| millis <= bound } || @buckets.size
          stats.record_end(event.status.code, event.duration, bucket)
        end
      end
    end

    # A consistent copy of the counters of every method seen so far.
    def snapshot : Hash(String, MethodStats)
      @mutex.synchronize { @methods.transform_values(&.dup) }
    end
  end
end
