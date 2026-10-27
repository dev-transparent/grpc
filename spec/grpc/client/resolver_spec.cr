require "./client_helper"

private alias Address = GRPC::Resolver::Address

# Collects resolver results.
private class Results
  @results = [] of GRPC::Resolver::Result
  @mutex = Mutex.new

  def listener : GRPC::Resolver::Listener
    ->(result : GRPC::Resolver::Result) { @mutex.synchronize { @results << result }; nil }
  end

  def to_a
    @mutex.synchronize { @results.dup }
  end

  def size
    to_a.size
  end

  def wait_for(count : Int32, timeout = 5.seconds) : Array(GRPC::Resolver::Result)
    ClientSpec.wait_until(timeout, "#{count} results") { size >= count }
    to_a
  end
end

private def build(target : String) : {GRPC::Resolver, Results}
  parsed = GRPC::Target.parse(target)
  results = Results.new
  resolver = GRPC::Resolver.provider(parsed.scheme).not_nil!.build(parsed, results.listener)
  {resolver, results}
end

private def resolve(target : String) : GRPC::Resolver::Result
  resolver, results = build(target)
  resolver.start
  results.wait_for(1).first
ensure
  resolver.try &.shutdown
end

describe GRPC::Target do
  it "parses targets per naming.md" do
    target = GRPC::Target.parse("dns:///example.com:50051")
    {target.scheme, target.authority, target.endpoint, target.hierarchical?}.should eq({"dns", "", "example.com:50051", true})

    target = GRPC::Target.parse("dns:example.com")
    {target.scheme, target.endpoint, target.hierarchical?}.should eq({"dns", "example.com", false})

    target = GRPC::Target.parse("dns://8.8.8.8/example.com")
    {target.authority, target.endpoint}.should eq({"8.8.8.8", "example.com"})

    target = GRPC::Target.parse("ipv4:127.0.0.1:1,127.0.0.1:2")
    {target.scheme, target.endpoint}.should eq({"ipv4", "127.0.0.1:1,127.0.0.1:2"})

    target = GRPC::Target.parse("unix:///tmp/sock")
    {target.scheme, target.endpoint, target.hierarchical?}.should eq({"unix", "tmp/sock", true})

    target = GRPC::Target.parse("UNIX:relative.sock")
    {target.scheme, target.endpoint}.should eq({"unix", "relative.sock"})
  end

  it "falls back to dns for bare and unknown targets" do
    {"localhost:50051", "127.0.0.1:50051", "[::1]:50051", "example.com", "unknown:///x"}.each do |string|
      target = GRPC::Target.parse(string)
      target.scheme.should eq "dns"
      target.endpoint.should eq string
    end
  end
end

describe GRPC::Resolver do
  it "splits host and port" do
    GRPC::Resolver.split_host_port("host:1").should eq({"host", 1})
    GRPC::Resolver.split_host_port("host").should eq({"host", 443})
    GRPC::Resolver.split_host_port("[::1]:50051").should eq({"::1", 50051})
    GRPC::Resolver.split_host_port("[::1]").should eq({"::1", 443})
    GRPC::Resolver.split_host_port("::1").should eq({"::1", 443})
    GRPC::Resolver.split_host_port("host", 80).should eq({"host", 80})
    {"host:x", "host:70000", "[::1", "[::1]x", ":1", ""}.each do |bad|
      expect_raises(ArgumentError) { GRPC::Resolver.split_host_port(bad) }
    end
  end

  it "formats addresses" do
    Address.tcp("::1", 5).to_s.should eq "[::1]:5"
    Address.tcp("10.0.0.1", 5).to_s.should eq "10.0.0.1:5"
    Address.unix("/tmp/s").to_s.should eq "unix:/tmp/s"
    Address.parse("unix:///tmp/s").should eq Address.unix("/tmp/s")
    Address.parse("unix:rel").should eq Address.unix("rel")
    Address.parse("[::1]:7").should eq Address.tcp("::1", 7)
  end

  it "resolves ipv4 and ipv6 targets statically" do
    resolve("ipv4:127.0.0.1:1,10.0.0.2").addresses.should eq [Address.tcp("127.0.0.1", 1), Address.tcp("10.0.0.2", 443)]
    resolve("ipv4:///127.0.0.1:9").addresses.should eq [Address.tcp("127.0.0.1", 9)]
    resolve("ipv6:[::1]:50051,::2").addresses.should eq [Address.tcp("::1", 50051), Address.tcp("::2", 443)]
    resolve("ipv4:not-an-ip:1").error.not_nil!.should contain "Invalid IPv4"
  end

  it "resolves unix and passthrough targets" do
    resolve("unix:/tmp/a.sock").addresses.should eq [Address.unix("/tmp/a.sock")]
    resolve("unix:///tmp/a.sock").addresses.should eq [Address.unix("/tmp/a.sock")]
    resolve("unix:rel.sock").addresses.should eq [Address.unix("rel.sock")]
    resolve("passthrough:///some.host:8080").addresses.should eq [Address.tcp("some.host", 8080)]
  end

  it "rejects malformed targets when creating a channel" do
    expect_raises(ArgumentError, /Invalid IPv4/) { GRPC::Channel.new("ipv4:1.2.3:4") }
    expect_raises(ArgumentError, /Invalid IPv6/) { GRPC::Channel.new("ipv6:[zz]:1") }
    expect_raises(ArgumentError, /authority/) { GRPC::Channel.new("ipv4://auth/127.0.0.1:1") }
    expect_raises(ArgumentError, /Custom DNS servers/) { GRPC::Channel.new("dns://8.8.8.8/example.com") }
    expect_raises(ArgumentError, /Invalid port/) { GRPC::Channel.new("example.com:http") }
    expect_raises(ArgumentError, /Empty UNIX/) { GRPC::Channel.new("unix:") }
    {% unless flag?(:linux) %}
      expect_raises(ArgumentError, /only supported on Linux/) { GRPC::Channel.new("unix-abstract:name") }
    {% end %}
  end

  it "derives the default authority" do
    GRPC::Channel.new("dns:///example.com:50051").authority.should eq "example.com:50051"
    GRPC::Channel.new("example.com").authority.should eq "example.com"
    GRPC::Channel.new("ipv4:127.0.0.1:1,127.0.0.1:2").authority.should eq "127.0.0.1:1"
    GRPC::Channel.new("unix:/tmp/x").authority.should eq "localhost"
    GRPC::Channel.new("passthrough:///h:1").authority.should eq "h:1"
    GRPC::Channel.new("https://example.com:8443/").authority.should eq "example.com:8443"
    GRPC::Channel.new("https://example.com:8443/").secure?.should be_true
    GRPC::Channel.new("http://example.com").http2.port.should eq 80
    GRPC::Channel.new("example.com").http2.port.should eq 443
  end

  describe GRPC::DNSResolver do
    it "returns all addresses of a host and IP literals without lookup" do
      lookups = Atomic(Int32).new(0)
      provider = GRPC::DNSResolver::Provider.new do |host, port|
        lookups.add(1)
        host.should eq "svc.test"
        [Address.tcp("10.0.0.1", port), Address.tcp("::1", port)]
      end
      results = Results.new
      resolver = provider.build(GRPC::Target.parse("dns:///svc.test:81"), results.listener)
      resolver.start
      results.wait_for(1).first.addresses.should eq [Address.tcp("10.0.0.1", 81), Address.tcp("::1", 81)]
      resolver.shutdown

      resolver = provider.build(GRPC::Target.parse("127.0.0.1:5"), results.listener)
      resolver.start
      results.wait_for(2).last.addresses.should eq [Address.tcp("127.0.0.1", 5)]
      resolver.shutdown
      lookups.get.should eq 1
    end

    it "resolves localhost with the system resolver" do
      result = resolve("dns:///localhost:1234")
      result.error.should be_nil
      result.addresses.should_not be_empty
      result.addresses.all? { |address| address.port == 1234 }.should be_true
    end

    it "retries failed lookups with backoff" do
      calls = Atomic(Int32).new(0)
      provider = GRPC::DNSResolver::Provider.new(backoff: GRPC::ConnectionBackoff.new(initial: 20.milliseconds, max: 40.milliseconds)) do |_, port|
        raise Socket::Error.new("not found") if calls.add(1) < 2
        [Address.tcp("10.0.0.9", port)]
      end
      results = Results.new
      resolver = provider.build(GRPC::Target.parse("svc:1"), results.listener)
      resolver.start
      list = results.wait_for(3)
      list[0].error.not_nil!.should contain "failed"
      list[1].error.not_nil!.should contain "failed"
      list[2].addresses.should eq [Address.tcp("10.0.0.9", 1)]
      resolver.shutdown
    end

    it "re-resolves on request, rate limited by min_interval" do
      calls = Atomic(Int32).new(0)
      provider = GRPC::DNSResolver::Provider.new(min_interval: 300.milliseconds, refresh_interval: nil) do |_, port|
        calls.add(1)
        [Address.tcp("10.0.0.#{calls.get}", port)]
      end
      results = Results.new
      resolver = provider.build(GRPC::Target.parse("svc:1"), results.listener)
      started = Time.instant
      resolver.start
      results.wait_for(1)
      resolver.resolve_now
      resolver.resolve_now
      list = results.wait_for(2)
      (Time.instant - started).should be >= 290.milliseconds
      list[1].addresses.should eq [Address.tcp("10.0.0.2", 1)]
      sleep 100.milliseconds
      results.size.should eq 2 # coalesced
      resolver.shutdown
    end

    it "refreshes periodically" do
      provider = GRPC::DNSResolver::Provider.new(min_interval: 10.milliseconds, refresh_interval: 30.milliseconds) do |_, port|
        [Address.tcp("10.0.0.1", port)]
      end
      results = Results.new
      resolver = provider.build(GRPC::Target.parse("svc:1"), results.listener)
      resolver.start
      results.wait_for(3)
      resolver.shutdown
      count = results.size
      sleep 100.milliseconds
      results.size.should be <= count + 1
    end

    it "reports empty results as errors" do
      provider = GRPC::DNSResolver::Provider.new(refresh_interval: nil) { |_, _| [] of Address }
      results = Results.new
      resolver = provider.build(GRPC::Target.parse("svc:1"), results.listener)
      resolver.start
      results.wait_for(1).first.error.not_nil!.should contain "no addresses"
      resolver.shutdown
    end
  end

  describe GRPC::ManualResolver do
    it "delivers updates to channels and counts re-resolution requests" do
      resolver = GRPC::ManualResolver.new("spec-manual", authority: "my.service")
      ClientSpec.with_servers(2) do |servers|
        channel = GRPC::Channel.new("spec-manual:///anything", resolver: resolver, backoff: ClientSpec::FAST_BACKOFF)
        channel.authority.should eq "my.service"
        client = ClientSpec::Client.new(channel)
        resolver.update([servers[0].address])
        client.unary(ClientSpec::EchoRequest.new(message: "name")).message.should eq "s0"

        # Moving to another address replaces the connection.
        resolver.update([servers[1].address])
        ClientSpec.wait_until { client.unary(ClientSpec::EchoRequest.new(message: "name")).message == "s1" }

        # A lost connection triggers re-resolution.
        before = resolver.resolve_now_count
        servers[1].close
        ClientSpec.wait_until { resolver.resolve_now_count > before }
        channel.shutdown
      end
    end

    it "is usable from the registry" do
      resolver = GRPC::ManualResolver.new("spec-registered")
      GRPC::Resolver.register(resolver)
      begin
        ClientSpec.with_servers(1) do |servers|
          resolver.update([servers[0].address])
          channel = GRPC::Channel.new("spec-registered:///x")
          ClientSpec::Client.new(channel).unary(ClientSpec::EchoRequest.new(message: "name")).message.should eq "s0"
          channel.shutdown
        end
      ensure
        GRPC::Resolver.unregister("spec-registered")
      end
    end

    it "fails fast on resolution errors, and wait-for-ready calls wait for addresses" do
      resolver = GRPC::ManualResolver.new("spec-failing")
      ClientSpec.with_servers(1) do |servers|
        channel = GRPC::Channel.new("spec-failing:///x", resolver: resolver)
        client = ClientSpec::Client.new(channel)
        resolver.fail("no such service")
        error = GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { client.unary(ClientSpec::EchoRequest.new) }
        error.status.message.should contain "no such service"
        channel.state.should eq GRPC::ConnectivityState::TransientFailure

        waiting = GRPCSpec.async { client.with_options(wait_for_ready: true).unary(ClientSpec::EchoRequest.new(message: "name")).message }
        sleep 50.milliseconds
        resolver.update([servers[0].address])
        GRPCSpec.await(waiting).should eq "s0"
        channel.shutdown
      end
    end
  end
end
