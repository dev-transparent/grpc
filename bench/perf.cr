# Performance benchmarks, used by the PR performance comparison
# (.github/workflows/perf.yml, script/perf/run.sh).
#
#   crystal build --release bench/perf.cr -o bin/perf
#   bin/perf                          # all benchmarks, JSON lines on stdout
#   bin/perf --only=micro             # micro benchmarks only
#   bin/perf --bench=hpack_decode --iterations=1000
#                                     # fixed iterations of one benchmark
#                                     # (used to count instructions)
#   bin/perf --list
#
# Every result is one JSON object per line:
#   {"bench":"hpack_decode","metric":"time","value":812.4,"unit":"ns/op","better":"lower"}
#
# Micro benchmarks report time per operation and bytes allocated per
# operation; macro benchmarks run a real server and client over loopback
# and report throughput and latency.

# Hashing is seeded randomly per process, which changes collision patterns
# and so the work done by hash lookups from run to run. Use a fixed seed
# (before any library code runs) so that instruction counts reproduce.
struct Crystal::Hasher
  def self.fix_seed : Nil
    @@seed = StaticArray[0x9e3779b97f4a7c15_u64, 0xbf58476d1ce4e5b9_u64]
  end
end

Crystal::Hasher.fix_seed

require "json"
require "option_parser"
require "../src/grpc"
require "../spec/grpc/generated/test_service_grpc.pb"
require "../spec/protobuf/generated/google/protobuf/test_messages_proto3.pb"

module Perf
  alias Proto3 = ProtobufTestMessages::Proto3
  alias Pb = GrpcSpec

  record Result, bench : String, metric : String, value : Float64, unit : String, better : String do
    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "bench", bench
        json.field "metric", metric
        json.field "value", value.round(3)
        json.field "unit", unit
        json.field "better", better
      end
    end
  end

  # A micro benchmark: a block run repeatedly.
  record Micro, name : String, block : Proc(Nil)

  def self.emit(result : Result) : Nil
    STDOUT.puts result.to_json
    STDOUT.flush
  end

  # --- Fixtures ---

  REQUEST_HEADERS = [
    {":method", "POST"}, {":scheme", "http"}, {":path", "/helloworld.Greeter/SayHello"},
    {":authority", "api.internal:50051"}, {"content-type", "application/grpc"}, {"te", "trailers"},
    {"user-agent", "grpc-crystal/0.1.0"}, {"grpc-accept-encoding", "gzip,deflate,identity"},
    {"grpc-timeout", "2999876u"}, {"authorization", "Bearer eyJhbGciOiJIUzI1NiJ9.e30.ZRrHA1JJJW8opsbCGfG_HACGpVUMN_a9IV7pAx_Zmeo"},
    {"x-request-id", "4b3c1a8e-6f2d-4e2b-9a71-3f5c9d0e2a11"},
  ]

  def self.rich_message : Proto3::TestAllTypesProto3
    Proto3::TestAllTypesProto3.new(
      optional_int32: -12345, optional_int64: 9_876_543_210_i64, optional_uint32: 4_000_000_000_u32,
      optional_sint64: -42_i64, optional_fixed64: 123_u64, optional_double: 3.14159, optional_bool: true,
      optional_string: "the quick brown fox jumps over the lazy dog",
      optional_bytes: Bytes.new(64) { |i| i.to_u8 },
      optional_nested_message: Proto3::TestAllTypesProto3::NestedMessage.new(a: 7),
      optional_nested_enum: Proto3::TestAllTypesProto3::NestedEnum::BAR,
      repeated_int32: (1..50).to_a, repeated_double: (1..20).map(&.to_f),
      repeated_string: (1..10).map { |i| "item-#{i}" },
      repeated_nested_message: (1..10).map { |i| Proto3::TestAllTypesProto3::NestedMessage.new(a: i) },
      map_string_string: {"alpha" => "1", "beta" => "2", "gamma" => "3"},
    )
  end

  def self.micro_benchmarks : Array(Micro)
    benches = [] of Micro

    encoder = HTTP2::HPACK::Encoder.new
    benches << Micro.new("hpack_encode", -> { encoder.encode(REQUEST_HEADERS); nil })

    block = HTTP2::HPACK::Encoder.new.encode(REQUEST_HEADERS)
    benches << Micro.new("hpack_decode", -> { HTTP2::HPACK::Decoder.new.decode(block); nil })

    small = Pb::EchoRequest.new(message: "hello world", count: 3, sleep_ms: 0)
    small_bytes = small.to_protobuf
    benches << Micro.new("protobuf_encode_small", -> { small.to_protobuf; nil })
    benches << Micro.new("protobuf_decode_small", -> { Pb::EchoRequest.from_protobuf(small_bytes); nil })

    rich = rich_message
    rich_bytes = rich.to_protobuf
    benches << Micro.new("protobuf_encode_rich", -> { rich.to_protobuf; nil })
    benches << Micro.new("protobuf_decode_rich", -> { Proto3::TestAllTypesProto3.from_protobuf(rich_bytes); nil })

    rich_json = rich.to_json
    benches << Micro.new("protobuf_json_encode", -> { rich.to_json; nil })
    benches << Micro.new("protobuf_json_decode", -> { Proto3::TestAllTypesProto3.from_json(rich_json); nil })

    payload = Bytes.new(1024) { |i| (i % 251).to_u8 }
    framed = GRPC::Framing.encode(payload)
    benches << Micro.new("grpc_frame_encode_1k", -> { GRPC::Framing.encode(payload); nil })
    benches << Micro.new("grpc_frame_read_1k", -> { GRPC::Framing.read(IO::Memory.new(framed), nil, Int32::MAX); nil })

    frames = IO::Memory.new
    100.times do |i|
      id = (i * 2 + 1).to_u32
      HTTP2::HeadersFrame.new(id, block, end_headers: true).write(frames)
      HTTP2::DataFrame.new(id, payload, end_stream: true).write(frames)
      HTTP2::WindowUpdateFrame.new(0_u32, 1024_u32).write(frames)
    end
    frame_bytes = frames.to_slice
    benches << Micro.new("http2_frame_parse_300", -> {
      io = IO::Memory.new(frame_bytes)
      while HTTP2::Frame.read(io)
      end
      nil
    })
    benches
  end

  # Runs *micro* for about *duration* (after a warm-up) and reports time
  # and allocations per operation.
  def self.run_micro(micro : Micro, duration : Time::Span) : Nil
    block = micro.block
    # Warm up and calibrate a batch size taking ~10ms.
    batch = 1
    loop do
      started = Time.instant
      batch.times { block.call }
      break if started.elapsed > 10.milliseconds || batch > 10_000_000
      batch *= 2
    end

    GC.collect
    bytes_before = GC.stats.total_bytes
    iterations = 0_i64
    started = Time.instant
    while started.elapsed < duration
      batch.times { block.call }
      iterations += batch
    end
    elapsed = started.elapsed
    allocated = GC.stats.total_bytes - bytes_before

    emit Result.new(micro.name, "time", elapsed.total_nanoseconds / iterations, "ns/op", "lower")
    emit Result.new(micro.name, "alloc", allocated.to_f / iterations, "B/op", "lower")
  end

  # --- Macro benchmarks ---

  class Service < Pb::TestService::Service
    def unary(request, context)
      Pb::EchoResponse.new(message: request.message, payload: Bytes.new(request.response_size))
    end

    def server_stream(request, responses, context)
      payload = Bytes.new(request.response_size)
      request.count.times { |i| responses << Pb::EchoResponse.new(index: i, payload: payload) }
    end

    def client_stream(requests, context)
      Pb::Summary.new(count: requests.size)
    end

    def bidi(requests, responses, context)
      requests.each { |request| responses << Pb::EchoResponse.new(message: request.message) }
    end

    def ping(request, context)
      Pb::Empty.new
    end
  end

  def self.with_server(&) : Nil
    server = GRPC::Server.new
    server.handle(Service.new)
    port = server.bind("127.0.0.1:0").as(Socket::IPAddress).port
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    client = Pb::TestService::Client.new(channel)
    client.ping(Pb::Empty.new)
    begin
      yield client
    ensure
      channel.shutdown
      server.close(1.second)
    end
  end

  # Runs *workers* fibers calling *operation* for *duration*, then reports
  # throughput, latency percentiles and allocations per operation.
  def self.closed_loop(name : String, workers : Int32, duration : Time::Span, warmup : Time::Span, &operation : -> Nil) : Nil
    latencies = [] of Time::Span
    stop_at = Time.instant + warmup + duration
    record_from = Time.instant + warmup
    count = 0_i64
    bytes_before = 0_u64
    done = Channel(Nil).new
    workers.times do
      spawn do
        while (now = Time.instant) < stop_at
          started = Time.instant
          operation.call
          if started >= record_from
            latencies << started.elapsed
            count += 1
          end
        end
        done.send(nil)
      end
    end
    sleep warmup
    GC.collect
    bytes_before = GC.stats.total_bytes
    measure_start = Time.instant
    workers.times { done.receive }
    elapsed = measure_start.elapsed
    allocated = GC.stats.total_bytes - bytes_before
    latencies.sort!
    p = ->(q : Float64) { latencies.empty? ? 0.0 : latencies[(q * (latencies.size - 1)).to_i].total_microseconds }

    emit Result.new(name, "throughput", count / elapsed.total_seconds, "ops/s", "higher")
    emit Result.new(name, "p50", p.call(0.5), "us", "lower")
    emit Result.new(name, "p99", p.call(0.99), "us", "lower")
    emit Result.new(name, "alloc", count > 0 ? allocated.to_f / count : 0.0, "B/op", "lower")
  end

  def self.run_macro(duration : Time::Span) : Nil
    warmup = duration / 4
    with_server do |client|
      small = Pb::EchoRequest.new(message: "hello")
      closed_loop("grpc_unary_small_c32", 32, duration, warmup) { client.unary(small); nil }
      closed_loop("grpc_unary_small_c1", 1, duration, warmup) { client.unary(small); nil }

      large = Pb::EchoRequest.new(payload: Bytes.new(64 * 1024), response_size: 64 * 1024)
      closed_loop("grpc_unary_64k_c16", 16, duration, warmup) { client.unary(large); nil }

      stream_request = Pb::EchoRequest.new(count: 64, response_size: 64 * 1024)
      bytes = 0_i64
      closed_loop("grpc_server_stream_64k", 4, duration, warmup) do
        client.server_stream(stream_request).each { |response| bytes += response.payload.size }
        nil
      end

      calls = Array.new(16) { client.bidi }
      index = Atomic(Int32).new(0)
      message = Pb::EchoRequest.new(message: "ping")
      closed_loop("grpc_bidi_pingpong_c16", 16, duration, warmup) do
        call = calls[index.add(1) % calls.size]
        call.send(message)
        call.receive?
        nil
      end
      calls.each do |call|
        call.close_send
        call.to_a
      end
    end
  end
end

only = "all"
bench = nil
iterations = nil
duration = 1.second
macro_duration = 4.seconds
OptionParser.parse do |parser|
  parser.on("--only=KIND", "micro, macro or all") { |v| only = v }
  parser.on("--bench=NAME", "Run one micro benchmark") { |v| bench = v }
  parser.on("--iterations=N", "Fixed iteration count (with --bench)") { |v| iterations = v.to_i64 }
  parser.on("--duration=SECONDS", "Measurement time per micro benchmark") { |v| duration = v.to_f.seconds }
  parser.on("--macro-duration=SECONDS", "Measurement time per macro benchmark") { |v| macro_duration = v.to_f.seconds }
  parser.on("--list", "List micro benchmarks") do
    Perf.micro_benchmarks.each { |micro| puts micro.name }
    exit
  end
end
Log.setup(:none)

micros = Perf.micro_benchmarks
if name = bench
  micro = micros.find(&.name.== name) || abort("Unknown benchmark #{name}")
  if count = iterations
    # Fixed work, e.g. for instruction counting under cachegrind. The GC
    # is disabled so that collections, which happen at arbitrary points,
    # don't add noise to the count.
    GC.disable
    count.times { micro.block.call }
  else
    Perf.run_micro(micro, duration)
  end
  exit
end

micros.each { |micro| Perf.run_micro(micro, duration) } if only.in?("all", "micro")
Perf.run_macro(macro_duration) if only.in?("all", "macro")
