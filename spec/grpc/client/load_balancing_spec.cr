require "./client_helper"

private alias State = GRPC::ConnectivityState

private def name_of(client : ClientSpec::Client) : String
  client.unary(ClientSpec::EchoRequest.new(message: "name")).message
end

private def round_robin_config : String
  %({"loadBalancingConfig": [{"round_robin": {}}]})
end

# Drops calls whose metadata has "x-drop", else delegates to pick_first's
# behaviour of using the first READY subchannel.
private class DroppingPolicy < GRPC::LoadBalancer
  class Provider < GRPC::LoadBalancer::Provider
    def name : String
      "spec_dropping"
    end

    def build(helper : GRPC::LoadBalancer::Helper) : GRPC::LoadBalancer
      DroppingPolicy.new(helper)
    end
  end

  class Picker < GRPC::LoadBalancer::Picker
    def initialize(@subchannel : GRPC::Subchannel?)
    end

    def pick(info : GRPC::LoadBalancer::PickInfo) : GRPC::LoadBalancer::PickResult
      if info.metadata.has_key?("x-drop")
        return GRPC::LoadBalancer::PickResult.drop(GRPC::Status.new(GRPC::StatusCode::Unavailable, "dropped by policy"))
      end
      if subchannel = @subchannel
        GRPC::LoadBalancer::PickResult.complete(subchannel)
      else
        GRPC::LoadBalancer::PickResult.queue
      end
    end
  end

  @subchannel : GRPC::Subchannel? = nil

  def initialize(@helper : GRPC::LoadBalancer::Helper)
  end

  def update(addresses : Array(GRPC::Resolver::Address), config : JSON::Any) : Nil
    return if @subchannel
    subchannel = @helper.create_subchannel(addresses.first)
    @subchannel = subchannel
    subchannel.watch do |state|
      if state.ready?
        @helper.update_state(State::Ready, Picker.new(subchannel))
      elsif state.idle?
        subchannel.request_connection
      end
    end
    @helper.update_state(State::Connecting, Picker.new(nil))
    subchannel.request_connection
  end

  def resolver_error(message : String) : Nil
  end

  def exit_idle : Nil
  end

  def shutdown : Nil
    @subchannel.try &.shutdown
  end
end

GRPC::LoadBalancer.register(DroppingPolicy::Provider.new)

describe "GRPC load balancing" do
  describe "pick_first" do
    it "is the default and uses the first address that connects" do
      ClientSpec.with_servers(2) do |servers|
        down = ClientSpec.free_port
        channel = GRPC::Channel.new("ipv4:127.0.0.1:#{down},#{servers[1].address},#{servers[0].address}",
          backoff: ClientSpec::FAST_BACKOFF)
        client = ClientSpec::Client.new(channel)
        5.times { name_of(client).should eq "s1" }
        channel.load_balancing_policy.should eq "pick_first"
        channel.shutdown
      end
    end

    it "fails over to the next address when the connection is lost" do
      ClientSpec.with_servers(2) do |servers|
        channel = GRPC::Channel.new("ipv4:#{servers[0].address},#{servers[1].address}", backoff: ClientSpec::FAST_BACKOFF)
        client = ClientSpec::Client.new(channel)
        name_of(client).should eq "s0"
        servers[0].close
        ClientSpec.wait_until { channel.state.idle? }
        name_of(client).should eq "s1"
        channel.shutdown
      end
    end

    it "reports TRANSIENT_FAILURE when every address fails" do
      ports = Array.new(2) { ClientSpec.free_port }
      channel = GRPC::Channel.new("ipv4:127.0.0.1:#{ports[0]},127.0.0.1:#{ports[1]}", backoff: ClientSpec::FAST_BACKOFF)
      GRPCSpec.within do
        error = GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { ClientSpec::Client.new(channel).unary(ClientSpec::EchoRequest.new) }
        error.status.message.should contain "Failed to connect to all addresses"
        channel.state.should eq State::TransientFailure
      end
      channel.shutdown
    end

    it "shuffles addresses when configured" do
      ClientSpec.with_servers(4) do |servers|
        addresses = servers.map(&.address).join(',')
        config = %({"loadBalancingConfig": [{"pick_first": {"shuffleAddressList": true}}]})
        names = Array.new(12) do
          channel = GRPC::Channel.new("ipv4:#{addresses}", service_config: config)
          name = name_of(ClientSpec::Client.new(channel))
          channel.shutdown
          name
        end
        names.uniq.size.should be > 1
      end
    end

    it "validates its config" do
      expect_raises(GRPC::ServiceConfig::Error, /shuffleAddressList/) do
        GRPC::ServiceConfig.parse(%({"loadBalancingConfig": [{"pick_first": {"shuffleAddressList": 1}}]}))
      end
    end
  end

  describe "round_robin" do
    it "spreads calls over all servers" do
      ClientSpec.with_servers(3) do |servers|
        channel = GRPC::Channel.new("ipv4:#{servers.map(&.address).join(',')}", service_config: round_robin_config)
        client = ClientSpec::Client.new(channel)
        channel.connect(5.seconds).should be_true
        # Wait until every subchannel is READY.
        ClientSpec.wait_until { Array.new(6) { name_of(client) }.uniq.size == 3 }
        names = Array.new(30) { name_of(client) }
        names.tally.values.should eq [10, 10, 10]
        channel.load_balancing_policy.should eq "round_robin"
        channel.shutdown
      end
    end

    it "skips failed servers and reconnects to recovered ones" do
      ClientSpec.with_servers(2) do |servers|
        port = servers[1].port
        channel = GRPC::Channel.new("ipv4:#{servers.map(&.address).join(',')}", service_config: round_robin_config,
          backoff: ClientSpec::FAST_BACKOFF)
        client = ClientSpec::Client.new(channel)
        ClientSpec.wait_until { Array.new(4) { name_of(client) }.uniq.size == 2 }
        servers[1].close
        ClientSpec.wait_until { Array.new(4) { name_of(client) }.uniq == ["s0"] }
        Array.new(10) { name_of(client) }.uniq.should eq ["s0"]

        restarted = ClientSpec::TestServer.new(ClientSpec::NamedService.new("s1b"), port: port)
        begin
          ClientSpec.wait_until { Array.new(4) { name_of(client) }.includes?("s1b") }
        ensure
          restarted.close
        end
        channel.shutdown
      end
    end

    it "is TRANSIENT_FAILURE only when all servers fail" do
      ports = Array.new(2) { ClientSpec.free_port }
      channel = GRPC::Channel.new("ipv4:127.0.0.1:#{ports[0]},127.0.0.1:#{ports[1]}",
        load_balancing_policy: "round_robin", backoff: ClientSpec::FAST_BACKOFF)
      GRPCSpec.within do
        channel.connect
        ClientSpec.wait_until { channel.state.transient_failure? }
        GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { ClientSpec::Client.new(channel).unary(ClientSpec::EchoRequest.new) }
      end
      channel.shutdown
    end

    it "follows address updates from the resolver" do
      resolver = GRPC::ManualResolver.new("spec-rr")
      ClientSpec.with_servers(3) do |servers|
        resolver.update(servers[0, 2].map(&.address))
        channel = GRPC::Channel.new("spec-rr:///svc", resolver: resolver, service_config: round_robin_config)
        client = ClientSpec::Client.new(channel)
        ClientSpec.wait_until { Array.new(4) { name_of(client) }.uniq.sort == ["s0", "s1"] }
        resolver.update(servers[1, 2].map(&.address))
        ClientSpec.wait_until { Array.new(6) { name_of(client) }.uniq.sort == ["s1", "s2"] }
        channel.shutdown
      end
    end
  end

  it "switches policies when the resolver's service config changes" do
    resolver = GRPC::ManualResolver.new("spec-switch")
    ClientSpec.with_servers(2) do |servers|
      addresses = servers.map(&.address)
      resolver.update(addresses)
      channel = GRPC::Channel.new("spec-switch:///svc", resolver: resolver)
      client = ClientSpec::Client.new(channel)
      Array.new(4) { name_of(client) }.uniq.should eq ["s0"]
      channel.load_balancing_policy.should eq "pick_first"

      resolver.update(addresses, service_config: round_robin_config)
      ClientSpec.wait_until { Array.new(4) { name_of(client) }.uniq.size == 2 }
      channel.load_balancing_policy.should eq "round_robin"
      channel.shutdown
    end
  end

  it "rejects unknown policies" do
    expect_raises(ArgumentError, /Unknown load balancing policy/) { GRPC::Channel.new("localhost:1", load_balancing_policy: "nope") }
  end

  describe "custom policies and wait-for-ready" do
    it "drops calls even if they are wait-for-ready" do
      ClientSpec.with_servers(1) do |servers|
        channel = GRPC::Channel.new(servers[0].address, load_balancing_policy: "spec_dropping")
        client = ClientSpec::Client.new(channel, wait_for_ready: true)
        name_of(client).should eq "s0"
        error = GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) do
          client.unary(ClientSpec::EchoRequest.new, metadata: {"x-drop" => "1"})
        end
        error.status.message.should eq "dropped by policy"
        servers[0].impl.as(ClientSpec::NamedService).calls.get.should eq 1
        channel.shutdown
      end
    end

    it "queues wait-for-ready calls until the channel is READY, and fails others fast" do
      port = ClientSpec.free_port
      channel = GRPC::Channel.new("127.0.0.1:#{port}", backoff: ClientSpec::FAST_BACKOFF)
      client = ClientSpec::Client.new(channel)
      server = nil
      GRPCSpec.within do
        queued = GRPCSpec.async { client.with_options(wait_for_ready: true).unary(ClientSpec::EchoRequest.new(message: "queued")).message }
        ClientSpec.wait_until { channel.state.transient_failure? }
        GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { client.unary(ClientSpec::EchoRequest.new) }
        server = ClientSpec::TestServer.new(port: port)
        GRPCSpec.await(queued).should eq "queued"
      end
      channel.shutdown
      server.try &.close
    end

    it "fails queued wait-for-ready calls at their deadline" do
      port = ClientSpec.free_port
      channel = GRPC::Channel.new("127.0.0.1:#{port}", backoff: ClientSpec::FAST_BACKOFF)
      client = ClientSpec::Client.new(channel, wait_for_ready: true)
      GRPCSpec.within do
        started = Time.instant
        GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) { client.unary(ClientSpec::EchoRequest.new, deadline: 200.milliseconds) }
        (Time.instant - started).should be >= 190.milliseconds
      end
      channel.shutdown
    end
  end
end
