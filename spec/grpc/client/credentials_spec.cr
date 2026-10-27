require "./client_helper"

private alias Certs = ClientSpec::Certs
private alias Code = GRPC::StatusCode

private def require_openssl!
  pending!("openssl CLI not available") unless Certs.dir
end

# Records the authorization metadata seen by the server.
private class AuthEcho < GRPCSpec::TestServiceImpl
  def unary(request, context)
    GrpcSpec::EchoResponse.new(message: context.metadata.get_all("authorization").join(","), authority: context.authority || "")
  end
end

private def with_tls_server(name = "server", client_ca = false, &block : ClientSpec::TestServer ->) : Nil
  server = ClientSpec::TestServer.new(AuthEcho.new, tls: Certs.server_context(name, client_ca))
  begin
    GRPCSpec.within(15.seconds) { block.call(server) }
  ensure
    server.close
  end
end

private def call(channel : GRPC::Channel, **options) : GrpcSpec::EchoResponse
  ClientSpec::Client.new(channel, **options).unary(ClientSpec::EchoRequest.new)
ensure
  channel.shutdown
end

describe GRPC::ChannelCredentials do
  it "connects over TLS with a custom CA" do
    require_openssl!
    with_tls_server do |server|
      channel = GRPC::Channel.new(server.address, credentials: GRPC::ChannelCredentials.tls(ca_file: Certs.path("ca.pem")))
      channel.scheme.should eq "https"
      call(channel).authority.should eq server.address
      # Also with the CA given as PEM data, and the localhost name.
      creds = GRPC::ChannelCredentials.tls(ca_pem: File.read(Certs.path("ca.pem")))
      call(GRPC::Channel.new("localhost:#{server.port}", credentials: creds)).authority.should eq "localhost:#{server.port}"
    end
  end

  it "accepts an OpenSSL context and the tls: shortcut" do
    require_openssl!
    with_tls_server do |server|
      context = OpenSSL::SSL::Context::Client.new
      context.ca_certificates = Certs.path("ca.pem")
      call(GRPC::Channel.new(server.address, tls: context)).should be_a(GrpcSpec::EchoResponse)
      call(GRPC::Channel.new("https://#{server.address}", credentials: GRPC::ChannelCredentials.tls(context))).should be_a(GrpcSpec::EchoResponse)
    end
  end

  it "fails with UNAVAILABLE when the certificate is not trusted" do
    require_openssl!
    with_tls_server do |server|
      # System roots do not include the spec CA.
      error = GRPCSpec.expect_status(Code::Unavailable) { call(GRPC::Channel.new(server.address, tls: true)) }
      error.status.message.should contain "certificate"
      creds = GRPC::ChannelCredentials.tls(ca_file: Certs.path("other-ca.pem"))
      GRPCSpec.expect_status(Code::Unavailable) { call(GRPC::Channel.new(server.address, credentials: creds)) }
      # Verification can be disabled explicitly.
      call(GRPC::Channel.new(server.address, credentials: GRPC::ChannelCredentials.tls(verify: false)))
    end
  end

  it "fails when a plaintext channel talks to a TLS server" do
    require_openssl!
    with_tls_server do |server|
      GRPCSpec.expect_status(Code::Unavailable) do
        call(GRPC::Channel.new(server.address, backoff: GRPC::ConnectionBackoff.new(min_connect_timeout: 500.milliseconds)))
      end
    end
  end

  it "verifies against the server name override" do
    require_openssl!
    with_tls_server("override") do |server|
      creds = GRPC::ChannelCredentials.tls(ca_file: Certs.path("ca.pem"))
      error = GRPCSpec.expect_status(Code::Unavailable) { call(GRPC::Channel.new(server.address, credentials: creds)) }

      creds = GRPC::ChannelCredentials.tls(ca_file: Certs.path("ca.pem"), server_name_override: "override.test")
      channel = GRPC::Channel.new(server.address, credentials: creds)
      channel.authority.should eq "override.test"
      call(channel).authority.should eq "override.test"
    end
  end

  it "authenticates the client with mutual TLS" do
    require_openssl!
    with_tls_server(client_ca: true) do |server|
      anonymous = GRPC::ChannelCredentials.tls(ca_file: Certs.path("ca.pem"))
      GRPCSpec.expect_status(Code::Unavailable) { call(GRPC::Channel.new(server.address, credentials: anonymous)) }

      mutual = GRPC::ChannelCredentials.tls(ca_file: Certs.path("ca.pem"),
        cert_file: Certs.path("client.pem"), key_file: Certs.path("client.key"))
      call(GRPC::Channel.new(server.address, credentials: mutual)).should be_a(GrpcSpec::EchoResponse)

      pem = GRPC::ChannelCredentials.tls(ca_pem: File.read(Certs.path("ca.pem")),
        cert_pem: File.read(Certs.path("client.pem")), key_pem: File.read(Certs.path("client.key")))
      call(GRPC::Channel.new(server.address, credentials: pem)).should be_a(GrpcSpec::EchoResponse)
    end
  end

  it "validates arguments" do
    expect_raises(ArgumentError, /together/) { GRPC::ChannelCredentials.tls(cert_file: "x.pem") }
    expect_raises(ArgumentError, /not both/) { GRPC::ChannelCredentials.tls(ca_file: "a", ca_pem: "b") }
    GRPC::ChannelCredentials.insecure.secure?.should be_false
  end
end

describe GRPC::CallCredentials do
  it "adds metadata over secure channels" do
    require_openssl!
    with_tls_server do |server|
      tls = GRPC::ChannelCredentials.tls(ca_file: Certs.path("ca.pem"))
      call(GRPC::Channel.new(server.address, credentials: tls), call_credentials: GRPC::CallCredentials.bearer("abc"))
        .message.should eq "Bearer abc"

      # Channel-level call credentials compose with per-call ones.
      composite = tls.with_call_credentials(GRPC::CallCredentials.bearer("channel"))
      channel = GRPC::Channel.new(server.address, credentials: composite)
      client = ClientSpec::Client.new(channel)
      client.unary(ClientSpec::EchoRequest.new).message.should eq "Bearer channel"
      client.with_options(call_credentials: GRPC::CallCredentials.bearer("call")).unary(ClientSpec::EchoRequest.new)
        .message.should eq "Bearer channel,Bearer call"
      channel.shutdown
    end
  end

  it "passes the call context to providers" do
    require_openssl!
    with_tls_server do |server|
      contexts = [] of GRPC::CallCredentials::Context
      creds = GRPC::CallCredentials.new do |context|
        contexts << context
        {"authorization" => "Token #{context.method_name}"}
      end
      tls = GRPC::ChannelCredentials.tls(ca_file: Certs.path("ca.pem"))
      call(GRPC::Channel.new(server.address, credentials: tls), call_credentials: creds).message.should eq "Token Unary"
      context = contexts.first
      context.service_url.should eq "https://#{server.address}/grpc_spec.TestService"
      context.method_path.should eq ClientSpec::UNARY
      context.secure?.should be_true
    end
  end

  it "refuses to send credentials over plaintext unless allowed" do
    server = ClientSpec::TestServer.new(AuthEcho.new)
    begin
      GRPCSpec.within do
        error = GRPCSpec.expect_status(Code::Unauthenticated) do
          call(GRPC::Channel.new(server.address), call_credentials: GRPC::CallCredentials.bearer("abc"))
        end
        error.status.message.should contain "secure channel"
        call(GRPC::Channel.new(server.address), call_credentials: GRPC::CallCredentials.bearer("abc", allow_insecure: true))
          .message.should eq "Bearer abc"
        composite = GRPC::CallCredentials.bearer("a", allow_insecure: true) + GRPC::CallCredentials.bearer("b", allow_insecure: true)
        call(GRPC::Channel.new(server.address), call_credentials: composite).message.should eq "Bearer a,Bearer b"
        mixed = GRPC::CallCredentials.bearer("a", allow_insecure: true) + GRPC::CallCredentials.bearer("b")
        GRPCSpec.expect_status(Code::Unauthenticated) { call(GRPC::Channel.new(server.address), call_credentials: mixed) }
      end
    ensure
      server.close
    end
  end

  it "maps provider failures to statuses" do
    server = ClientSpec::TestServer.new(AuthEcho.new)
    begin
      GRPCSpec.within do
        failing = GRPC::CallCredentials.new(allow_insecure: true) { |_| raise "token service down" }
        error = GRPCSpec.expect_status(Code::Unavailable) { call(GRPC::Channel.new(server.address), call_credentials: failing) }
        error.status.message.should contain "token service down"

        denied = GRPC::CallCredentials.new(allow_insecure: true) { |_| raise GRPC::Error.new(Code::Unauthenticated, "expired") }
        GRPCSpec.expect_status(Code::Unauthenticated) { call(GRPC::Channel.new(server.address), call_credentials: denied) }

        # Codes reserved for applications become INTERNAL (gRFC A54).
        bad = GRPC::CallCredentials.new(allow_insecure: true) { |_| raise GRPC::Error.new(Code::InvalidArgument, "nope") }
        GRPCSpec.expect_status(Code::Internal) { call(GRPC::Channel.new(server.address), call_credentials: bad) }

        invalid = GRPC::CallCredentials.new(allow_insecure: true) { |_| {"Bad Key" => "x"} }
        GRPCSpec.expect_status(Code::Internal) { call(GRPC::Channel.new(server.address), call_credentials: invalid) }
      end
    ensure
      server.close
    end
  end
end
