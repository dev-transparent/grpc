# Soak test: runs a mixed gRPC workload against an in-process server for a
# fixed duration and checks the system stays healthy:
#
# * every RPC completes with the expected status (no unexpected errors),
# * no RPCs are left in flight on the server and no fibers leak,
# * the GC heap plateaus after warm-up (bounded growth).
#
#   crystal run --release bench/soak.cr -- --duration=300 --concurrency=64
#
# Exits non-zero if a check fails.
require "option_parser"
require "../src/grpc"
require "../spec/grpc/generated/test_service_grpc.pb"

duration = 60.seconds
concurrency = 32
max_heap_growth = 1.5 # allowed final/warm-up heap ratio
report_every = 10.seconds

OptionParser.parse do |parser|
  parser.on("--duration=SECONDS", "Total run time") { |v| duration = v.to_f.seconds }
  parser.on("--concurrency=N", "Concurrent workers") { |v| concurrency = v.to_i }
  parser.on("--max-heap-growth=RATIO", "Allowed heap growth after warm-up") { |v| max_heap_growth = v.to_f }
  parser.on("--report-every=SECONDS", "Progress report interval") { |v| report_every = v.to_f.seconds }
end

alias Spec = GrpcSpec

class SoakService < Spec::TestService::Service
  def unary(request, context)
    if request.status_code != 0
      raise GRPC::Error.new(GRPC::StatusCode.from_value(request.status_code), "requested")
    end
    sleep request.sleep_ms.milliseconds if request.sleep_ms > 0
    Spec::EchoResponse.new(message: request.message, payload: Bytes.new(request.response_size))
  end

  def server_stream(request, responses, context)
    request.count.times do |i|
      context.check_cancelled!
      responses << Spec::EchoResponse.new(index: i, payload: Bytes.new(request.response_size))
      sleep request.sleep_ms.milliseconds if request.sleep_ms > 0
    end
  end

  def client_stream(requests, context)
    count = 0
    total = 0_i64
    requests.each do |r|
      count += 1
      total += r.payload.size
    end
    Spec::Summary.new(count: count, total_bytes: total)
  end

  def bidi(requests, responses, context)
    requests.each { |r| responses << Spec::EchoResponse.new(message: r.message, payload: r.payload) }
  end

  def ping(request, context)
    Spec::Empty.new
  end
end

def fiber_count : Int32
  count = 0
  Fiber.unsafe_each { count += 1 }
  count
end

metrics = GRPC::MetricsCollector.new
server = GRPC::Server.new(stats_handlers: [metrics] of GRPC::StatsHandler, compression: nil)
server.handle(SoakService.new)
port = server.bind("127.0.0.1:0").as(Socket::IPAddress).port
server.start

channel = GRPC::Channel.new("127.0.0.1:#{port}")
client = Spec::TestService::Client.new(channel)
gzip_client = Spec::TestService::Client.new(channel, compression: "gzip")

calls = Atomic(Int64).new(0)
failures = [] of String
failures_mutex = Mutex.new
fail = ->(message : String) { failures_mutex.synchronize { failures << message if failures.size < 50 } }

# One iteration of the mixed workload, picked by *kind*.
run_one = ->(kind : Int32, random : Random) do
  case kind
  when 0 # small unary
    response = client.unary(Spec::EchoRequest.new(message: "u"), deadline: 10.seconds)
    fail.call("unary echo mismatch") unless response.message == "u"
  when 1 # large unary, compressed
    response = gzip_client.unary(Spec::EchoRequest.new(payload: Bytes.new(256 * 1024), response_size: 256 * 1024), deadline: 10.seconds)
    fail.call("large unary size") unless response.payload.size == 256 * 1024
  when 2 # expected error
    begin
      client.unary(Spec::EchoRequest.new(status_code: 5), deadline: 10.seconds)
      fail.call("expected NOT_FOUND")
    rescue e : GRPC::Error
      fail.call("unexpected #{e.code}") unless e.code.not_found?
    end
  when 3 # deadline exceeded
    begin
      client.unary(Spec::EchoRequest.new(sleep_ms: 200), deadline: 20.milliseconds)
      fail.call("expected DEADLINE_EXCEEDED")
    rescue e : GRPC::Error
      fail.call("unexpected #{e.code} (deadline)") unless e.code.deadline_exceeded?
    end
  when 4 # server stream, fully read
    count = client.server_stream(Spec::EchoRequest.new(count: 20, response_size: 1024), deadline: 10.seconds).size
    fail.call("stream count #{count}") unless count == 20
  when 5 # server stream, cancelled midway
    call = client.server_stream(Spec::EchoRequest.new(count: 1000, sleep_ms: 1), deadline: 10.seconds)
    call.receive?
    call.cancel
  when 6 # client stream
    summary = client.client_stream(deadline: 10.seconds) do |c|
      10.times { c << Spec::EchoRequest.new(payload: Bytes.new(4096)) }
    end
    fail.call("client stream count") unless summary.count == 10
  when 7 # bidi ping-pong
    call = client.bidi(deadline: 10.seconds)
    5.times do |i|
      call.send(Spec::EchoRequest.new(message: i.to_s))
      fail.call("bidi echo") unless call.receive?.try(&.message) == i.to_s
    end
    call.close_send
    fail.call("bidi end") unless call.receive?.nil?
  end
  calls.add(1)
rescue e : GRPC::Error
  fail.call("kind #{kind}: #{e.code} #{e.status.message}")
rescue e
  fail.call("kind #{kind}: #{e.class}: #{e.message}")
end

started = Time.instant
deadline = started + duration
warmup_end = started + Math.min(duration / 5, 30.seconds)
warmup_heap = 0_u64
done = Channel(Nil).new

concurrency.times do |worker|
  spawn do
    random = Random.new(worker)
    while Time.instant < deadline
      run_one.call(random.rand(8), random)
    end
    done.send(nil)
  end
end

spawn do
  loop do
    sleep report_every
    break if Time.instant >= deadline
    GC.collect
    heap = GC.stats.heap_size
    warmup_heap = heap if warmup_heap == 0 && Time.instant >= warmup_end
    elapsed = (Time.instant - started).total_seconds
    puts "[#{elapsed.round(1)}s] calls=#{calls.get} rate=#{(calls.get / elapsed).round}/s heap=#{heap // 1024}KiB fibers=#{fiber_count}"
  end
end

concurrency.times { done.receive }
sleep 500.milliseconds # let cancellations and stream closes settle
GC.collect
final_heap = GC.stats.heap_size
warmup_heap = final_heap if warmup_heap == 0

in_flight = metrics.snapshot.values.sum(&.in_flight)
completed = metrics.snapshot.values.sum { |m| m.completed.values.sum }
client.close
server.close(2.seconds)
sleep 200.milliseconds
fibers = fiber_count

puts "calls: #{calls.get} (server completed #{completed}) in #{duration.total_seconds}s"
puts "heap: warm-up #{warmup_heap // 1024}KiB, final #{final_heap // 1024}KiB"
puts "server RPCs still in flight: #{in_flight}; fibers after shutdown: #{fibers}"

problems = failures.dup
problems << "#{in_flight} RPCs still in flight on the server" if in_flight != 0
if final_heap > warmup_heap * max_heap_growth && final_heap - warmup_heap > 32 * 1024 * 1024
  problems << "heap grew from #{warmup_heap // 1024}KiB to #{final_heap // 1024}KiB"
end
problems << "#{fibers} fibers alive after shutdown (leak?)" if fibers > 16

if problems.empty?
  puts "SOAK OK"
else
  puts "SOAK FAILED:"
  problems.each { |problem| puts "  - #{problem}" }
  exit 1
end
