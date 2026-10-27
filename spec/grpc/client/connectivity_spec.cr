require "./client_helper"

private alias State = GRPC::ConnectivityState

# A TCP listener recording accepted connections; *respond* decides what to
# do with each (by default close it immediately).
private class Listener
  getter port : Int32
  @accepted = [] of Time::Instant
  @mutex = Mutex.new
  @sockets = [] of TCPSocket

  def initialize(@hold : Bool = false)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn do
      while socket = (@server.accept? rescue nil)
        @mutex.synchronize do
          @accepted << Time.instant
          @hold ? (@sockets << socket) : socket.close
        end
      end
    end
  end

  def accepted : Array(Time::Instant)
    @mutex.synchronize { @accepted.dup }
  end

  def close : Nil
    @server.close rescue nil
    @mutex.synchronize { @sockets.each { |s| s.close rescue nil } }
  end
end

private def wait_for_state(channel : GRPC::Channel, state : State, timeout = 5.seconds) : Nil
  ClientSpec.wait_until(timeout, "state #{state} (is #{channel.state})") { channel.state == state }
end

describe GRPC::Backoff do
  it "follows the connection backoff algorithm" do
    config = GRPC::ConnectionBackoff.new(initial: 1.second, multiplier: 1.6, jitter: 0.2, max: 120.seconds)
    backoff = GRPC::Backoff.new(config)
    backoff.next_delay.should eq 1.second
    expected = 1.0
    20.times do
      expected = Math.min(expected * 1.6, 120.0)
      delay = backoff.next_delay.total_seconds
      delay.should be >= expected * 0.8 - 1e-9
      delay.should be <= expected * 1.2 + 1e-9
    end
    backoff.reset
    backoff.next_delay.should eq 1.second
  end

  it "has the spec defaults and validates parameters" do
    config = GRPC::ConnectionBackoff.new
    {config.initial, config.multiplier, config.jitter, config.max, config.min_connect_timeout}
      .should eq({1.second, 1.6, 0.2, 120.seconds, 20.seconds})
    expect_raises(ArgumentError) { GRPC::ConnectionBackoff.new(initial: Time::Span.zero) }
    expect_raises(ArgumentError) { GRPC::ConnectionBackoff.new(initial: 2.seconds, max: 1.second) }
    expect_raises(ArgumentError) { GRPC::ConnectionBackoff.new(multiplier: 0.5) }
    expect_raises(ArgumentError) { GRPC::ConnectionBackoff.new(jitter: 1.0) }
  end
end

describe "GRPC::Channel connectivity" do
  it "starts IDLE and connects on demand" do
    server = ClientSpec::TestServer.new
    channel = GRPC::Channel.new(server.address)
    begin
      GRPCSpec.within do
        channel.state.should eq State::Idle
        sleep 20.milliseconds
        channel.state.should eq State::Idle
        channel.wait_for_state_change(State::Idle, 20.milliseconds).should be_false

        channel.state(try_to_connect: true).should eq State::Connecting
        channel.wait_for_state_change(State::Connecting, 5.seconds).should be_true
        channel.state.should eq State::Ready
        channel.connect(1.second).should be_true
      end
    ensure
      channel.shutdown
      server.close
    end
  end

  it "connects on the first call" do
    server = ClientSpec::TestServer.new
    channel = GRPC::Channel.new(server.address)
    begin
      GRPCSpec.within do
        ClientSpec::Client.new(channel).unary(ClientSpec::EchoRequest.new(message: "x")).message.should eq "x"
        channel.state.should eq State::Ready
      end
    ensure
      channel.shutdown
      server.close
    end
  end

  it "backs off exponentially between failed connection attempts" do
    listener = Listener.new
    backoff = GRPC::ConnectionBackoff.new(initial: 100.milliseconds, multiplier: 2.0, jitter: 0.0, max: 1.second)
    channel = GRPC::Channel.new("127.0.0.1:#{listener.port}", backoff: backoff)
    begin
      GRPCSpec.within do
        channel.connect
        ClientSpec.wait_until { listener.accepted.size >= 4 }
        times = listener.accepted
        intervals = times.each_cons(2).map { |(a, b)| (b - a).total_milliseconds }.to_a
        intervals[0].should be >= 90
        intervals[1].should be >= 190
        intervals[2].should be >= 390
        intervals[0].should be < 400
        channel.state.should eq State::TransientFailure
      end
    ensure
      channel.shutdown
      listener.close
    end
  end

  it "gives each attempt at least min_connect_timeout" do
    listener = Listener.new(hold: true)
    backoff = GRPC::ConnectionBackoff.new(initial: 20.milliseconds, max: 50.milliseconds, min_connect_timeout: 300.milliseconds)
    channel = GRPC::Channel.new("127.0.0.1:#{listener.port}", backoff: backoff)
    begin
      GRPCSpec.within do
        started = Time.instant
        channel.connect
        channel.state.should eq State::Connecting
        wait_for_state(channel, State::TransientFailure)
        (Time.instant - started).should be >= 290.milliseconds
      end
    ensure
      channel.shutdown
      listener.close
    end
  end

  it "stays in TRANSIENT_FAILURE while retrying and recovers when the server comes up" do
    port = ClientSpec.free_port
    channel = GRPC::Channel.new("127.0.0.1:#{port}", backoff: ClientSpec::FAST_BACKOFF)
    server = nil
    begin
      GRPCSpec.within do
        GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { ClientSpec::Client.new(channel).unary(ClientSpec::EchoRequest.new) }
        channel.state.should eq State::TransientFailure
        # Sticky: CONNECTING attempts are not reported while failing.
        5.times do
          sleep 30.milliseconds
          channel.state.should eq State::TransientFailure
        end
        server = ClientSpec::TestServer.new(port: port)
        wait_for_state(channel, State::Ready)
        ClientSpec::Client.new(channel).unary(ClientSpec::EchoRequest.new(message: "up")).message.should eq "up"
      end
    ensure
      channel.shutdown
      server.try &.close
    end
  end

  it "retries immediately after reset_connect_backoff" do
    port = ClientSpec.free_port
    channel = GRPC::Channel.new("127.0.0.1:#{port}", backoff: GRPC::ConnectionBackoff.new(initial: 30.seconds, max: 60.seconds))
    server = nil
    begin
      GRPCSpec.within do
        channel.connect
        wait_for_state(channel, State::TransientFailure)
        server = ClientSpec::TestServer.new(port: port)
        sleep 100.milliseconds
        channel.state.should eq State::TransientFailure
        channel.reset_connect_backoff
        wait_for_state(channel, State::Ready)
      end
    ensure
      channel.shutdown
      server.try &.close
    end
  end

  it "goes IDLE when the connection is lost and reconnects on the next call" do
    server = ClientSpec::TestServer.new
    port = server.port
    channel = GRPC::Channel.new(server.address)
    client = ClientSpec::Client.new(channel)
    begin
      GRPCSpec.within do
        client.unary(ClientSpec::EchoRequest.new).should be_a(ClientSpec::EchoResponse)
        server.close
        wait_for_state(channel, State::Idle)
        server = ClientSpec::TestServer.new(port: port)
        client.unary(ClientSpec::EchoRequest.new(message: "again")).message.should eq "again"
        channel.state.should eq State::Ready
      end
    ensure
      channel.shutdown
      server.close
    end
  end

  it "stops using a connection after GOAWAY while its calls finish" do
    server = ClientSpec::TestServer.new
    channel = GRPC::Channel.new(server.address, backoff: ClientSpec::FAST_BACKOFF)
    client = ClientSpec::Client.new(channel)
    begin
      GRPCSpec.within do
        client.unary(ClientSpec::EchoRequest.new)
        slow = GRPCSpec.async { client.unary(ClientSpec::EchoRequest.new(message: "slow", sleep_ms: 400)).message }
        server.impl.events.wait_for("start Unary")
        closing = GRPCSpec.async { server.server.close(5.seconds); true }
        # The listener is gone: the next call cannot reuse the draining
        # connection and fails to reconnect.
        ClientSpec.wait_until { channel.state != State::Ready }
        GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { client.unary(ClientSpec::EchoRequest.new) }
        GRPCSpec.await(slow).should eq "slow"
        GRPCSpec.await(closing).should be_true
      end
    ensure
      channel.shutdown
      server.close
    end
  end

  it "enters idle mode after idle_timeout and leaves it on the next call" do
    server = ClientSpec::TestServer.new
    channel = GRPC::Channel.new(server.address, idle_timeout: 150.milliseconds)
    client = ClientSpec::Client.new(channel)
    begin
      GRPCSpec.within do
        client.unary(ClientSpec::EchoRequest.new)
        channel.state.should eq State::Ready
        # A long call keeps the channel active.
        client.unary(ClientSpec::EchoRequest.new(sleep_ms: 300))
        channel.state.should eq State::Ready
        channel.wait_for_state_change(State::Ready, 2.seconds).should be_true
        channel.state.should eq State::Idle
        client.unary(ClientSpec::EchoRequest.new(message: "back")).message.should eq "back"
        channel.state.should eq State::Ready
      end
    ensure
      channel.shutdown
      server.close
    end
  end

  it "returns to IDLE on close and can be reused" do
    server = ClientSpec::TestServer.new
    channel = GRPC::Channel.new(server.address)
    client = ClientSpec::Client.new(channel)
    begin
      GRPCSpec.within do
        client.unary(ClientSpec::EchoRequest.new)
        channel.close
        channel.state.should eq State::Idle
        client.unary(ClientSpec::EchoRequest.new(message: "reused")).message.should eq "reused"
      end
    ensure
      channel.shutdown
      server.close
    end
  end

  it "fails calls after shutdown" do
    server = ClientSpec::TestServer.new
    channel = GRPC::Channel.new(server.address)
    client = ClientSpec::Client.new(channel)
    begin
      GRPCSpec.within do
        client.unary(ClientSpec::EchoRequest.new)
        waiter = GRPCSpec.async { channel.wait_for_state_change(State::Ready, 5.seconds) }
        channel.shutdown
        GRPCSpec.await(waiter).should be_true
        channel.state.should eq State::Shutdown
        channel.shutdown?.should be_true
        channel.connect(100.milliseconds).should be_false
        error = GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { client.unary(ClientSpec::EchoRequest.new) }
        error.status.message.should contain "shut down"
      end
    ensure
      server.close
    end
  end

  it "fails queued wait-for-ready calls when the channel shuts down" do
    port = ClientSpec.free_port
    channel = GRPC::Channel.new("127.0.0.1:#{port}", backoff: ClientSpec::FAST_BACKOFF)
    client = ClientSpec::Client.new(channel, wait_for_ready: true)
    GRPCSpec.within do
      pending = GRPCSpec.async { client.unary(ClientSpec::EchoRequest.new) }
      sleep 100.milliseconds
      channel.shutdown
      result = GRPCSpec.await(pending)
      result.should be_a(GRPC::Error)
      result.as(GRPC::Error).code.should eq GRPC::StatusCode::Unavailable
    end
  end

  it "connects over UNIX sockets" do
    path = GRPCSpec.unused_unix_path
    server = GRPC::Server.new
    server.handle(GRPCSpec::TestServiceImpl.new)
    server.bind("unix:#{path}")
    server.start
    channel = GRPC::Channel.new("unix://#{path}")
    begin
      GRPCSpec.within do
        ClientSpec::Client.new(channel).unary(ClientSpec::EchoRequest.new(message: "unix")).authority.should eq "localhost"
      end
    ensure
      channel.shutdown
      server.close(1.second)
      File.delete?(path)
    end
  end
end
