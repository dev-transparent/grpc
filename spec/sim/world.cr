require "./network"
require "../../src/grpc"
require "../grpc/generated/test_service_grpc.pb"

module Sim
  alias Pb = GrpcSpec

  # Parameters of one simulation, all derived from the seed.
  class Config
    getter servers : Int32
    getter clients : Int32
    getter workers_per_client : Int32
    getter duration : Time::Span
    getter faults : Bool
    getter fault_interval : Range(Int32, Int32) # milliseconds between faults
    getter load_balancing : String
    getter retry_mode : Symbol # :none, :retry or :hedging
    getter client_keepalive : Bool
    getter connection_age : Time::Span?
    getter large_payloads : Bool

    def initialize(random : Random, @duration : Time::Span, @faults : Bool = true)
      @servers = 1 + random.rand(3)
      @clients = 1 + random.rand(4)
      @workers_per_client = 1 + random.rand(8)
      @fault_interval = (200..3_000)
      @load_balancing = random.next_bool ? "round_robin" : "pick_first"
      @retry_mode = {:none, :none, :retry, :hedging}.sample(random)
      @client_keepalive = random.rand < 0.5
      @connection_age = random.rand < 0.3 ? (2 + random.rand(8)).seconds : nil
      @large_payloads = random.rand < 0.3
    end

    def to_s(io : IO) : Nil
      io << "servers=" << @servers << " clients=" << @clients << " workers=" << @workers_per_client
      io << " lb=" << @load_balancing << " retries=" << @retry_mode << " keepalive=" << @client_keepalive
      io << " age=" << (@connection_age || "none") << " large=" << @large_payloads << " faults=" << @faults
    end

    # The service config used by clients.
    def service_config : GRPC::ServiceConfig
      method = case @retry_mode
               when :retry
                 GRPC::ServiceConfig::MethodConfig.new(
                   names: [GRPC::ServiceConfig::MethodName.new("grpc_spec.TestService")],
                   retry_policy: GRPC::ServiceConfig::RetryPolicy.new(
                     max_attempts: 3, initial_backoff: 10.milliseconds, max_backoff: 100.milliseconds,
                     backoff_multiplier: 2.0, retryable_status_codes: Set{GRPC::StatusCode::Unavailable}))
               when :hedging
                 GRPC::ServiceConfig::MethodConfig.new(
                   names: [GRPC::ServiceConfig::MethodName.new("grpc_spec.TestService", "Unary")],
                   hedging_policy: GRPC::ServiceConfig::HedgingPolicy.new(
                     max_attempts: 3, hedging_delay: 20.milliseconds,
                     non_fatal_status_codes: Set{GRPC::StatusCode::Unavailable}))
               end
      policy = @load_balancing == "round_robin" ? GRPC::RoundRobinConfig.new : GRPC::PickFirstConfig.new
      GRPC::ServiceConfig.new(
        load_balancing_config: [policy] of GRPC::LoadBalancingConfig,
        method_configs: method ? [method] : [] of GRPC::ServiceConfig::MethodConfig)
    end

    # The most times a request may legitimately execute on servers.
    def max_executions : Int32
      @retry_mode == :none ? 1 : 3
    end
  end

  # What servers executed, by request id.
  class Ledger
    @executions = Hash(String, Int32).new(0)

    def record(id : String) : Nil
      @executions[id] += 1 unless id.empty?
    end

    def executions(id : String) : Int32
      @executions[id]
    end
  end

  # The service run by every simulated server.
  class Service < Pb::TestService::Service
    def initialize(@ledger : Ledger)
    end

    def unary(request, context)
      @ledger.record(request.message)
      nap(request.sleep_ms, context)
      fail_if_requested(request)
      Pb::EchoResponse.new(message: request.message, payload: Bytes.new(request.response_size))
    end

    def server_stream(request, responses, context)
      @ledger.record(request.message)
      request.count.times do |index|
        if request.fail_after > 0 && index == request.fail_after
          raise GRPC::Error.new(:aborted, "failed after #{index}")
        end
        nap(request.sleep_ms, context)
        responses << Pb::EchoResponse.new(message: request.message, index: index, payload: Bytes.new(request.response_size))
      end
    end

    def client_stream(requests, context)
      messages = [] of String
      requests.each do |request|
        @ledger.record(request.message) if messages.empty?
        messages << request.message
      end
      Pb::Summary.new(count: messages.size, messages: messages)
    end

    def bidi(requests, responses, context)
      index = 0
      requests.each do |request|
        @ledger.record(request.message) if index == 0
        nap(request.sleep_ms, context)
        responses << Pb::EchoResponse.new(message: request.message, index: index)
        index += 1
      end
    end

    def ping(request, context)
      Pb::Empty.new
    end

    private def nap(ms : Int32, context) : Nil
      return if ms <= 0
      sleep ms.milliseconds
      context.check_cancelled!
    end

    private def fail_if_requested(request) : Nil
      return if request.status_code == 0
      code = GRPC::StatusCode.from_value?(request.status_code) || GRPC::StatusCode::Unknown
      raise GRPC::Error.new(code, request.status_message)
    end
  end

  # A server process at a fixed address that can crash and restart.
  class ServerNode
    AGE_GRACE = 2.seconds

    getter host : String
    getter address : String
    getter generation = 0
    getter servers = [] of GRPC::Server

    @server : GRPC::Server? = nil

    def initialize(@network : Network, @ledger : Ledger, @index : Int32, @config : Config)
      @host = "10.0.1.#{@index + 1}"
      @address = "#{@host}:50051"
    end

    def up? : Bool
      !@server.nil?
    end

    def start : Nil
      options = HTTP2::Server.default_options
      if @config.client_keepalive
        options.min_ping_interval = 500.milliseconds
        options.permit_without_stream = true
      end
      if age = @config.connection_age
        options.max_connection_age = age
        options.max_connection_age_grace = AGE_GRACE
      end
      server = GRPC::Server.new(connection_options: options)
      server.handle(Service.new(@ledger))
      @server = server
      @servers << server
      @generation += 1
      @network.listen(@address) { |endpoint| server.handle_connection(endpoint) }
      @network.trace.event("server #{@address} up (generation #{@generation})")
    end

    # Abrupt crash: connections are reset and the port refuses connects.
    def crash : Nil
      return unless @server
      @network.unlisten(@address)
      @network.reset_host(@host)
      @server = nil
      @network.trace.event("server #{@address} crashed")
    end

    # Graceful shutdown: GOAWAY and drain within *grace*.
    def drain(grace : Time::Span) : Nil
      server = @server || return
      @network.unlisten(@address)
      @server = nil
      @network.trace.event("server #{@address} draining")
      spawn(name: "sim-drain #{@address}") { server.close(grace) }
    end
  end

  # The outcome of one call, checked by the oracle.
  class Op
    getter id : String
    getter kind : Symbol
    getter started : Time::Span
    property finished : Time::Span? = nil
    property code : GRPC::StatusCode? = nil
    property message : String = ""
    getter deadline : Time::Span

    def extend_deadline(by : Time::Span) : Nil
      @deadline += by
    end

    property cancelled = false
    property requested_code : GRPC::StatusCode? = nil
    property expected_count = 0
    property sent = [] of String
    property received = [] of String
    property received_indexes = [] of Int32
    property summary_count : Int32? = nil
    # How long the server handler deliberately runs.
    property server_time : Time::Span = Time::Span.zero

    def initialize(@id : String, @kind : Symbol, @deadline : Time::Span)
      @started = Sim.elapsed
    end
  end

  # One simulated client host: a channel and workers issuing calls.
  class ClientNode
    getter host : String
    getter channel : GRPC::Channel
    getter resolver : GRPC::ManualResolver
    getter ops = [] of Op

    @stub : Pb::TestService::Client
    @counter = 0

    def initialize(@network : Network, @index : Int32, @config : Config, @world : World)
      @host = "10.0.2.#{@index + 1}"
      @resolver = GRPC::ManualResolver.new("sim#{@index}")
      @resolver.update(@world.server_addresses)
      network = @network
      host = @host
      keepalive = @config.client_keepalive ? GRPC::KeepaliveOptions.new(1.second, 2.seconds, permit_without_calls: true) : nil
      @channel = GRPC::Channel.new("sim#{@index}:///test", resolver: @resolver,
        service_config: @config.service_config, keepalive: keepalive,
        backoff: GRPC::ConnectionBackoff.new(initial: 100.milliseconds, max: 2.seconds,
          min_connect_timeout: 3.seconds),
        dialer: ->(address : GRPC::Resolver::Address, deadline : Time::Instant) {
          network.connect(host, address.to_s).as(IO)
        })
      @stub = Pb::TestService::Client.new(@channel)
    end

    # Runs one worker until *stop_at* (virtual time since start).
    def work(worker : Int32, stop_at : Time::Span, random : Random) : Nil
      while Sim.elapsed < stop_at
        run_op(worker, random)
        sleep random.rand(20).milliseconds
      end
    end

    private def run_op(worker : Int32, random : Random) : Nil
      id = "c#{@index}w#{worker}n#{@counter += 1}"
      deadline = (50 + random.rand(3_000)).milliseconds
      roll = random.rand(100)
      kind = if roll < 37
               :unary
             elsif roll < 40
               :bulk
             elsif roll < 60
               :server_stream
             elsif roll < 75
               :client_stream
             elsif roll < 90
               :bidi
             else
               :cancel
             end
      op = Op.new(id, kind, deadline)
      @ops << op
      @network.trace.event("op #{id} #{kind} start deadline=#{deadline}")
      begin
        case kind
        when :unary         then unary(op, random)
        when :server_stream then server_stream(op, random, cancel_after: nil)
        when :client_stream then client_stream(op, random)
        when :bidi          then bidi(op, random)
        when :cancel        then server_stream(op, random, cancel_after: random.rand(200).milliseconds)
        when :bulk          then bulk(op, random)
        end
        op.code = GRPC::StatusCode::Ok
      rescue e : GRPC::Error
        op.code = e.code
        op.message = e.status.message
      end
      op.finished = Sim.elapsed
      @network.trace.event("op #{id} end #{op.code} received=#{op.received.size}")
    end

    private def payload(random : Random) : Bytes
      size = @config.large_payloads && random.rand < 0.2 ? random.rand(256 * 1024) : random.rand(64)
      Bytes.new(size)
    end

    private def unary(op : Op, random : Random) : Nil
      request = Pb::EchoRequest.new(message: op.id, payload: payload(random),
        response_size: @config.large_payloads && random.rand < 0.2 ? random.rand(256 * 1024) : random.rand(64),
        sleep_ms: sleep_ms(random))
      if random.rand < 0.1
        code = {GRPC::StatusCode::NotFound, GRPC::StatusCode::InvalidArgument, GRPC::StatusCode::Unavailable}.sample(random)
        request = Pb::EchoRequest.new(message: op.id, status_code: code.value, status_message: "requested")
        op.requested_code = code
      end
      op.sent << op.id
      op.server_time = request.sleep_ms.milliseconds
      response = @stub.unary(request, deadline: op.deadline)
      op.received << response.message
    end

    private def server_stream(op : Op, random : Random, cancel_after : Time::Span?) : Nil
      count = random.rand(20)
      fail_after = random.rand < 0.1 && count > 1 ? 1 + random.rand(count - 1) : 0
      op.requested_code = GRPC::StatusCode::Aborted if fail_after > 0
      op.expected_count = count
      request = Pb::EchoRequest.new(message: op.id, count: count, fail_after: fail_after,
        sleep_ms: cancel_after ? 20 : random.rand(5), response_size: random.rand(1024))
      op.sent << op.id
      call = @stub.server_stream(request, deadline: op.deadline)
      if cancel_after
        spawn(name: "sim-cancel #{op.id}") do
          sleep cancel_after
          op.cancelled = true
          call.cancel
        end
      end
      while response = call.receive?
        op.received << response.message
        op.received_indexes << response.index
      end
    end

    private def client_stream(op : Op, random : Random) : Nil
      count = 1 + random.rand(10)
      summary = @stub.client_stream(deadline: op.deadline) do |call|
        count.times do |i|
          message = i == 0 ? op.id : "#{op.id}-#{i}"
          op.sent << message
          call << Pb::EchoRequest.new(message: message, payload: payload(random))
          sleep random.rand(10).milliseconds
        end
      end
      op.summary_count = summary.count
      op.received = summary.messages
    end

    private def bidi(op : Op, random : Random) : Nil
      count = 1 + random.rand(10)
      call = @stub.bidi(deadline: op.deadline)
      count.times do |i|
        message = i == 0 ? op.id : "#{op.id}-#{i}"
        op.sent << message
        call.send(Pb::EchoRequest.new(message: message, sleep_ms: random.rand(5)))
        if response = call.receive?
          op.received << response.message
          op.received_indexes << response.index
        else
          break
        end
      end
      call.close_send
      while response = call.receive?
        op.received << response.message
      end
    end

    # Pushes several stream windows' worth of data through one long-lived
    # bidi stream (each message is echoed back), so flow-control credit
    # must be returned correctly in both directions.
    private def bulk(op : Op, random : Random) : Nil
      count = 20 + random.rand(40)
      size = 64 * 1024 + random.rand(64 * 1024)
      op.extend_deadline(5.seconds)
      call = @stub.bidi(deadline: op.deadline)
      spawn(name: "sim-bulk-send #{op.id}") do
        count.times do |i|
          message = i == 0 ? op.id : "#{op.id}-#{i}"
          op.sent << message
          call.send(Pb::EchoRequest.new(message: message, payload: Bytes.new(size)))
        end
        call.close_send
      rescue GRPC::Error
      end
      while response = call.receive?
        op.received << response.message
      end
    end

    private def sleep_ms(random : Random) : Int32
      random.rand < 0.05 ? 1_000 + random.rand(4_000) : random.rand(30)
    end
  end

  # A complete simulated deployment: servers, clients, workload, faults and
  # the correctness oracle.
  class World
    getter network : Network
    getter config : Config
    getter servers = [] of ServerNode
    getter clients = [] of ClientNode
    getter violations = [] of String
    getter ledger = Ledger.new
    @baseline_fibers = Set(UInt64).new

    def initialize(@config : Config, @trace : Trace)
      @network = Network.new(@trace)
      @random = Random::PCG32.new(Sim.rng.next_u.to_u64)
    end

    def server_addresses : Array(String)
      @servers.map(&.address)
    end

    # Runs the simulation and returns the violations found.
    def run : Array(String)
      # Fibers that exist before the simulation (runtime, logging) are not
      # leaks.
      Fiber.unsafe_each { |fiber| @baseline_fibers << fiber.object_id unless fiber.dead? }
      @trace.event("config #{@config}")
      @config.servers.times { |i| @servers << ServerNode.new(@network, @ledger, i, @config).tap(&.start) }
      @config.clients.times { |i| @clients << ClientNode.new(@network, i, @config, self) }

      done = ::Channel(Nil).new
      workers = 0
      @clients.each do |client|
        @config.workers_per_client.times do |worker|
          workers += 1
          random = Random::PCG32.new(@random.next_u.to_u64)
          spawn(name: "sim-worker #{client.host}/#{worker}") do
            client.work(worker, @config.duration, random)
          ensure
            done.send(nil)
          end
        end
      end
      chaos_done = ::Channel(Nil).new
      spawn(name: "sim-chaos") do
        chaos if @config.faults
      ensure
        chaos_done.send(nil)
      end

      # Every call has a deadline below 5s; allow generous time to finish.
      finished = 0
      limit = @config.duration + 60.seconds
      while finished < workers
        select
        when done.receive
          finished += 1
        when timeout(Math.max(limit - Sim.elapsed, 1.millisecond))
          @violations << "liveness: #{workers - finished} worker(s) still running at #{Sim.elapsed} (calls hung past their deadlines)"
          break
        end
      end
      chaos_done.receive
      check_ops
      shutdown_and_check_leaks
      @violations
    end

    # --- Faults ---

    private def chaos : Nil
      restore = [] of {Time::Span, Proc(Nil)}
      while Sim.elapsed < @config.duration
        sleep (@config.fault_interval.begin + @random.rand(@config.fault_interval.size)).milliseconds
        restore.select! do |(at, action)|
          next true if Sim.elapsed < at
          action.call
          false
        end
        break if Sim.elapsed >= @config.duration
        inject_fault(restore)
      end
      restore.each(&.[1].call)
      @network.heal_all
      @network.latency = 200.microseconds
      @servers.each { |server| server.start unless server.up? }
      @clients.each &.resolver.update(server_addresses)
      @trace.event("chaos over: all faults healed")
    end

    private def inject_fault(restore : Array({Time::Span, Proc(Nil)})) : Nil
      until_ = Sim.elapsed + (200 + @random.rand(4_000)).milliseconds
      case @random.rand(7)
      when 0 # partition a client from a server
        client = @clients.sample(@random)
        server = @servers.sample(@random)
        one_way = @random.next_bool
        @network.partition(client.host, server.host, one_way)
        network = @network
        restore << {until_, -> { network.heal(client.host, server.host) }}
      when 1 # reset a server's connections
        server = @servers.sample(@random)
        @network.reset_host(server.host)
      when 2 # crash a server, restart later
        server = @servers.sample(@random)
        if server.up?
          server.crash
          restore << {until_, -> { server.start unless server.up? }}
        end
      when 3 # graceful restart
        server = @servers.sample(@random)
        if server.up?
          server.drain((@random.rand(2_000)).milliseconds)
          restore << {Sim.elapsed + 100.milliseconds, -> { server.start unless server.up? }}
        end
      when 4 # latency spike
        @network.latency = (20 + @random.rand(300)).milliseconds
        @trace.event("latency #{@network.latency}")
        network = @network
        trace = @trace
        restore << {until_, -> { network.latency = 200.microseconds; trace.event("latency normal") }}
      when 5 # resolver churn: a client sees a subset of the servers
        client = @clients.sample(@random)
        subset = server_addresses.shuffle(@random)[0, 1 + @random.rand(@servers.size)]
        client.resolver.update(subset)
        @trace.event("resolver #{client.host} -> #{subset.join(",")}")
        world = self
        restore << {until_, -> { client.resolver.update(world.server_addresses) }}
      when 6 # tiny segments and a small window for a while
        @network.max_segment = 1 + @random.rand(64)
        @network.window = 1 + @random.rand(4_096)
        @trace.event("network segment=#{@network.max_segment} window=#{@network.window}")
        network = @network
        restore << {until_, -> { network.max_segment = 16_384; network.window = 1 << 20 }}
      end
    end

    # --- Oracle ---

    ALLOWED_FAILURES = Set{GRPC::StatusCode::Unavailable, GRPC::StatusCode::DeadlineExceeded}
    # Slack for deadlines: the deadline timer fires exactly on time, but a
    # result racing with it may be processed in the same instant.
    DEADLINE_SLACK = 50.milliseconds

    private def check_ops : Nil
      @clients.each do |client|
        client.ops.each { |op| check(op) }
      end
    end

    private def check(op : Op) : Nil
      finished = op.finished
      code = op.code
      unless finished && code
        violation(op, "never completed")
        return
      end
      if finished - op.started > op.deadline + DEADLINE_SLACK
        violation(op, "completed after #{finished - op.started}, deadline #{op.deadline} (#{code})")
      end
      executions = @ledger.executions(op.id)
      if executions > @config.max_executions
        violation(op, "executed #{executions} times (max #{@config.max_executions})")
      end
      # Without faults the network never fails: only deadlines (handlers
      # may sleep past them), requested statuses and cancellations.
      allowed = @config.faults ? ALLOWED_FAILURES : Set{GRPC::StatusCode::DeadlineExceeded}
      # A connection that reaches its maximum age is closed after the grace
      # period even if calls are still running on it (gRFC A9).
      if (age = @config.connection_age) && op.server_time >= ServerNode::AGE_GRACE
        allowed = ALLOWED_FAILURES
      end
      unless code.ok? || allowed.includes?(code) || code == op.requested_code ||
             (code.cancelled? && op.cancelled)
        violation(op, "unexpected status #{code}: #{op.message}")
      end
      if code.ok? && op.requested_code && op.kind != :server_stream
        violation(op, "succeeded although #{op.requested_code} was requested")
      end

      case op.kind
      when :unary
        if code.ok?
          violation(op, "wrong response #{op.received}") unless op.received == [op.id]
          violation(op, "succeeded but never executed") if executions == 0
        end
      when :server_stream, :cancel
        indexes = op.received_indexes
        violation(op, "out of order or duplicated messages #{indexes}") unless indexes == (0...indexes.size).to_a
        violation(op, "wrong messages") unless op.received.all?(op.id)
        if code.ok? && !op.cancelled && indexes.size != op.expected_count
          violation(op, "received #{indexes.size} of #{op.expected_count} messages")
        end
      when :client_stream
        if code.ok?
          violation(op, "server saw #{op.summary_count} of #{op.sent.size} messages") unless op.summary_count == op.sent.size
          violation(op, "server saw #{op.received} instead of #{op.sent}") unless op.received == op.sent
        end
      when :bidi, :bulk
        if op.kind == :bulk && !@config.faults && !code.ok?
          violation(op, "bulk transfer failed without faults (#{code}): flow control or liveness problem")
        end
        violation(op, "echo #{op.received.first(3)}... is not a prefix of what was sent") unless op.received == op.sent[0, op.received.size]
        if code.ok? && op.received != op.sent
          violation(op, "echoed #{op.received.size} of #{op.sent.size} messages")
        end
      end
    end

    private def violation(op : Op, message : String) : Nil
      @violations << "#{op.id} (#{op.kind}, started #{op.started}): #{message}"
    end

    # --- Shutdown and leak checks ---

    private def shutdown_and_check_leaks : Nil
      @clients.each &.channel.shutdown(1.second)
      @servers.each do |node|
        node.servers.each { |server| spawn(name: "sim-close") { server.close(2.seconds) } }
      end
      sleep 30.seconds
      @trace.event("shutdown complete")

      open = @network.open_links
      unless open.empty?
        @violations << "leak: #{open.size} connection(s) still open after shutdown: #{open.first(5).map { |l| "#{l.client_address}->#{l.server_address}" }.join(", ")}"
      end
      @servers.each do |node|
        node.servers.each do |server|
          in_flight = server.call_metrics.started.get - server.call_metrics.succeeded.get - server.call_metrics.failed.get
          @violations << "leak: server #{node.address} has #{in_flight} call(s) in flight after shutdown" if in_flight != 0
          connections = server.http2.connections.size
          @violations << "leak: server #{node.address} still tracks #{connections} connection(s)" if connections != 0
        end
      end
      alive = [] of String
      Fiber.unsafe_each do |fiber|
        next if fiber.dead? || fiber == Fiber.current || @baseline_fibers.includes?(fiber.object_id)
        alive << (fiber.name || "unnamed")
      end
      unless alive.empty?
        @violations << "leak: #{alive.size} fiber(s) alive after shutdown: #{alive.tally.first(8).map { |n, c| "#{n} x#{c}" }.join(", ")}"
      end
    end
  end
end
