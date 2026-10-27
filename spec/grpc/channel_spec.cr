require "./grpc_helper"

describe GRPC::Channel do
  it "parses host:port targets" do
    channel = GRPC::Channel.new("example.com:50051")
    channel.scheme.should eq "http"
    channel.authority.should eq "example.com:50051"
    channel.target.should eq "example.com:50051"
    channel.user_agent.should eq "grpc-crystal/#{GRPC::VERSION}"
  end

  it "parses URL targets and default ports" do
    channel = GRPC::Channel.new("http://example.com:8080/")
    channel.scheme.should eq "http"
    channel.authority.should eq "example.com:8080"

    channel = GRPC::Channel.new("https://example.com")
    channel.scheme.should eq "https"
    channel.authority.should eq "example.com"

    channel = GRPC::Channel.new("example.com", tls: true)
    channel.scheme.should eq "https"
    channel.http2.port.should eq 443
  end

  it "supports UNIX socket targets and authority overrides" do
    GRPC::Channel.new("unix:/tmp/grpc.sock").authority.should eq "localhost"
    GRPC::Channel.new("unix:///tmp/grpc.sock", authority: "svc").authority.should eq "svc"
    GRPC::Channel.new("127.0.0.1:1", authority: "override.test").authority.should eq "override.test"
  end

  it "parses IPv6 addresses" do
    GRPC::Channel.parse_host_port("[::1]:50051", 80).should eq({"::1", 50051})
    GRPC::Channel.parse_host_port("[::1]", 443).should eq({"::1", 443})
    GRPC::Channel.parse_host_port("host:1", 80).should eq({"host", 1})
    GRPC::Channel.parse_host_port("host", 80).should eq({"host", 80})
  end

  it "uses a custom user agent" do
    GRPCSpec.with_server do |h|
      channel = GRPC::Channel.new(h.address, user_agent: "spec-agent/1.0")
      begin
        channel.user_agent.should eq "spec-agent/1.0"
        GRPCSpec::Client.new(channel).ping(GrpcSpec::Empty.new).should eq GrpcSpec::Empty.new
      ensure
        channel.close
      end
    end
  end

  it "sends the overridden authority" do
    GRPCSpec.with_server do |h|
      channel = GRPC::Channel.new(h.address, authority: "virtual.host")
      begin
        GRPCSpec::Client.new(channel).unary(GrpcSpec::EchoRequest.new).authority.should eq "virtual.host"
      ensure
        channel.close
      end
    end
  end
end

describe GRPC::CallInfo do
  it "holds the method, metadata and deadline" do
    info = GRPC::CallInfo.new("/s/m", GRPC::Metadata.new, nil)
    info.deadline.should be_nil
    info.timeout = 1.second
    remaining = info.deadline.not_nil! - Time.instant
    remaining.should be <= 1.second
    remaining.should be > 500.milliseconds
  end
end
