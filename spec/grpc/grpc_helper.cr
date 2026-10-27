require "../spec_helper"
require "../../src/grpc"
require "./generated/test_service_grpc.pb"

# Unhandled handler exceptions are logged by the server; keep spec output clean.
::Log.setup("grpc,grpc.*,http2,http2.*", :none)

module GRPCSpec
  alias EchoRequest = GrpcSpec::EchoRequest
  alias EchoResponse = GrpcSpec::EchoResponse
  alias Summary = GrpcSpec::Summary
  alias Empty = GrpcSpec::Empty
  alias Client = GrpcSpec::TestService::Client

  DEFAULT_TIMEOUT = 10.seconds

  # A thread-safe log of things the server observed, e.g. cancellations.
  # Specs wait for events with a timeout instead of sleeping.
  class Events
    @events = [] of String
    @mutex = Mutex.new

    def <<(event : String) : self
      @mutex.synchronize { @events << event }
      self
    end

    def to_a : Array(String)
      @mutex.synchronize { @events.dup }
    end

    def includes?(event : String) : Bool
      to_a.includes?(event)
    end

    # Waits until an event satisfying the block was recorded.
    def wait_for(timeout : Time::Span = 5.seconds, & : String -> Bool) : String
      deadline = Time.instant + timeout
      loop do
        if event = to_a.find { |e| yield e }
          return event
        end
        if Time.instant > deadline
          raise Spec::AssertionFailed.new("Timed out waiting for event; got #{to_a.inspect}", __FILE__, __LINE__)
        end
        sleep 2.milliseconds
      end
    end

    def wait_for(event : String, timeout : Time::Span = 5.seconds) : String
      wait_for(timeout) { |e| e == event }
    end
  end

  # Implementation of grpc_spec.TestService whose behaviour is driven by the
  # request fields (see spec/grpc/proto/test_service.proto).
  class TestServiceImpl < GrpcSpec::TestService::Service
    getter events = Events.new

    def unary(request, context)
      track(context)
      apply(request, context)
      response(request, context)
    end

    def server_stream(request, responses, context)
      track(context)
      apply_metadata(request, context)
      apply_compression(request, context)
      request.count.times do |i|
        if request.fail_after > 0 && i == request.fail_after
          fail_with(request)
        end
        nap(request, context)
        responses.send(response(request, context, i))
      end
      fail_with(request) if request.status_code != 0
      events << "server_stream done #{request.message}"
    end

    def client_stream(requests, context)
      track(context)
      summary = Summary.new
      requests.each do |request|
        apply(request, context)
        summary.count += 1
        summary.total_bytes += request.payload.size
        summary.messages << request.message
        summary.any_compressed = true if context.request_compressed?
      end
      events << "client_stream done"
      summary
    end

    def bidi(requests, responses, context)
      track(context)
      index = 0
      requests.each do |request|
        apply(request, context)
        Math.max(request.count, 1).times do
          responses.send(response(request, context, index))
          index += 1
        end
      end
      events << "bidi done"
    end

    def ping(request, context)
      GrpcSpec::Empty.new
    end

    private def track(context) : Nil
      events << "start #{context.method_name}"
      context.on_cancel do
        events << "on_cancel #{context.method_name} #{context.cancellation_code}"
      end
    end

    private def apply(request, context) : Nil
      apply_metadata(request, context)
      apply_compression(request, context)
      nap(request, context)
      fail_with(request)
    end

    private def apply_metadata(request, context) : Nil
      request.headers.each { |key, value| context.response_metadata.add(key, value) }
      request.trailers.each { |key, value| context.trailers.add(key, value) }
      context.metadata.each do |(key, value)|
        context.response_metadata.add(key, value) if key.starts_with?("x-echo-initial")
        context.trailers.add(key, value) if key.starts_with?("x-echo-trailing")
      end
    end

    private def apply_compression(request, context) : Nil
      context.compression = request.compression unless request.compression.empty?
    end

    private def fail_with(request) : Nil
      raise "boom: #{request.message}" if request.raise_exception
      return if request.status_code == 0
      code = GRPC::StatusCode.from_value?(request.status_code) || GRPC::StatusCode::Unknown
      raise GRPC::Error.new(code, request.status_message)
    end

    # Sleeps for `sleep_ms`, stopping early (and recording an event) when the
    # call is cancelled.
    private def nap(request, context) : Nil
      return if request.sleep_ms <= 0
      deadline = Time.instant + request.sleep_ms.milliseconds
      while Time.instant < deadline
        if context.cancelled?
          events << "cancelled #{context.method_name} #{context.cancellation_code} deadline_exceeded=#{context.deadline_exceeded?}"
          context.check_cancelled!
        end
        sleep 2.milliseconds
      end
    end

    private def response(request, context, index = 0) : EchoResponse
      metadata = {} of String => Bytes
      context.metadata.each { |(key, value)| metadata[key] = value.to_slice }
      EchoResponse.new(
        message: request.message,
        payload: Bytes.new(request.response_size),
        index: index,
        metadata: metadata,
        request_compressed: context.request_compressed?,
        timeout_ms: context.time_remaining.try(&.total_milliseconds.to_i64) || -1_i64,
        authority: context.authority || "",
        peer: context.peer || "",
        method_path: context.method_path,
      )
    end
  end

  # A running server plus a channel/client connected to it.
  class Harness
    getter server : GRPC::Server
    getter impl : TestServiceImpl
    getter address : String
    getter channel : GRPC::Channel
    getter client : Client

    def initialize(@server, @impl, @address)
      @channel = GRPC::Channel.new(@address)
      @client = Client.new(@channel)
    end

    def events : Events
      @impl.events
    end

    # A new client stub on the shared channel.
    def new_client(**options) : Client
      Client.new(@channel, **options)
    end

    def close : Nil
      @channel.close rescue nil
      @server.close(1.second) rescue nil
    end
  end

  # Starts a server on 127.0.0.1 port 0 serving *impl* and yields a harness.
  # The whole block is bounded by *timeout*.
  def self.with_server(impl : TestServiceImpl = TestServiceImpl.new, timeout : Time::Span = DEFAULT_TIMEOUT,
                       server : GRPC::Server = GRPC::Server.new, &block : Harness ->) : Nil
    server.handle(impl)
    address = server.bind_tcp("127.0.0.1", 0)
    server.start
    harness = Harness.new(server, impl, "127.0.0.1:#{address.port}")
    begin
      within(timeout) { block.call(harness) }
    ensure
      harness.close
    end
  end

  # Runs the block in a fiber and fails if it does not finish within
  # *timeout*. Exceptions raised by the block are re-raised.
  def self.within(timeout : Time::Span = DEFAULT_TIMEOUT, &block : -> _) : Nil
    done = ::Channel(Exception?).new(1)
    spawn(name: "spec-within") do
      block.call
      done.send(nil)
    rescue e
      done.send(e)
    end
    select
    when error = done.receive
      raise error if error
    when timeout(timeout)
      raise Spec::AssertionFailed.new("Timed out after #{timeout}", __FILE__, __LINE__)
    end
  end

  # Expects the block to raise a `GRPC::Error` with *code* and returns it.
  def self.expect_status(code : GRPC::StatusCode, file = __FILE__, line = __LINE__, &) : GRPC::Error
    begin
      yield
    rescue e : GRPC::Error
      unless e.code == code
        raise Spec::AssertionFailed.new("Expected #{code}, got #{e.code}: #{e.status.message}", file, line)
      end
      return e
    end
    raise Spec::AssertionFailed.new("Expected #{code}, but no error was raised", file, line)
  end

  # Runs *block* concurrently in a fiber, returning a channel with its
  # result (or exception).
  def self.async(&block : -> T) : ::Channel(T | Exception) forall T
    channel = ::Channel(T | Exception).new(1)
    spawn do
      channel.send(block.call)
    rescue e
      channel.send(e)
    end
    channel
  end

  # Receives from *channel* with a timeout.
  def self.await(channel : ::Channel(T), timeout : Time::Span = 5.seconds) : T forall T
    select
    when value = channel.receive
      value
    when timeout(timeout)
      raise Spec::AssertionFailed.new("Timed out after #{timeout} waiting for result", __FILE__, __LINE__)
    end
  end

  def self.unused_unix_path : String
    path = File.join(Dir.tempdir, "grpc-spec-#{Random::Secure.hex(6)}.sock")
    File.delete?(path)
    path
  end
end
