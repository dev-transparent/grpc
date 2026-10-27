require "./support"
require "file_utils"

private alias TLSFixture = HTTP2Spec::TLSFixture

private def require_openssl!
  pending!("openssl CLI not available") unless TLSFixture.paths
end

private def serve_tls(server : HTTP2::Server, host = "127.0.0.1", &block : HTTP2::Client ->)
  HTTP2Spec.bounded(30.seconds) do
    address = server.bind_tls("127.0.0.1", 0, TLSFixture.server_context)
    done = Channel(Nil).new(1)
    spawn { server.listen; done.send(nil) }
    client = HTTP2::Client.new(host, address.port, TLSFixture.client_context)
    begin
      block.call(client)
    ensure
      client.close rescue nil
      server.close(1.second)
      HTTP2Spec.receive(done)
    end
  end
end

describe "HTTP2 over TLS" do
  it "negotiates h2 with ALPN and serves requests" do
    require_openssl!
    server = HTTP2::Server.new do |ctx|
      ctx.response.print "#{ctx.request.scheme} #{ctx.request.path}"
    end
    serve_tls(server) do |client|
      client.tls?.should be_true
      client.scheme.should eq("https")
      response = client.get("/secure")
      response.status.should eq(200)
      response.body_text.should eq("https /secure")
    end
  end

  it "verifies the certificate against a host name" do
    require_openssl!
    server = HTTP2::Server.new { |ctx| ctx.response.print "ok" }
    serve_tls(server, host: "localhost") do |client|
      client.get("/").body_text.should eq("ok")
      client.connection.ping(5.seconds).should be < 5.seconds
    end
  end

  it "transfers large bodies in both directions" do
    require_openssl!
    server = HTTP2::Server.new do |ctx|
      buffer = Bytes.new(32_768)
      while (count = ctx.request.body.read(buffer)) > 0
        ctx.response.write(buffer[0, count])
      end
    end
    data = HTTP2Spec.random_bytes(3 * 1024 * 1024)
    serve_tls(server) do |client|
      stream = client.open_stream("POST", "/echo")
      spawn do
        stream.send_data(data)
        stream.close_send
      end
      response = HTTP2::Client::Response.new(stream)
      echoed = IO::Memory.new
      IO.copy(response.body, echoed)
      (echoed.to_slice == data).should be_true
    end
  end

  it "handles concurrent streams" do
    require_openssl!
    server = HTTP2::Server.new { |ctx| ctx.response.print ctx.request.path }
    serve_tls(server) do |client|
      results = Channel(String).new(50)
      50.times { |i| spawn { results.send(client.get("/#{i}").body_text) } }
      Array.new(50) { HTTP2Spec.receive(results) }.sort.should eq((0...50).map { |i| "/#{i}" }.sort)
    end
  end

  it "fails when the certificate cannot be verified" do
    require_openssl!
    server = HTTP2::Server.new { |ctx| ctx.response.print "ok" }
    HTTP2Spec.bounded do
      address = server.bind_tls("127.0.0.1", 0, TLSFixture.server_context)
      spawn { server.listen }
      client = HTTP2::Client.new("127.0.0.1", address.port, OpenSSL::SSL::Context::Client.new)
      expect_raises(OpenSSL::SSL::Error) { client.get("/") }
      server.close(1.second)
    end
  end

  it "closes connections from clients that do not negotiate h2" do
    require_openssl!
    server = HTTP2::Server.new { |ctx| ctx.response.print "ok" }
    HTTP2Spec.bounded do
      address = server.bind_tls("127.0.0.1", 0, TLSFixture.server_context)
      spawn { server.listen }
      context = TLSFixture.client_context
      context.alpn_protocol = "http/1.1"
      socket = TCPSocket.new("127.0.0.1", address.port)
      ssl = OpenSSL::SSL::Socket::Client.new(socket, context, sync_close: true, hostname: "127.0.0.1")
      ssl.alpn_protocol.should be_nil
      begin
        ssl.read(Bytes.new(16)).should eq(0)
      rescue IO::Error | OpenSSL::SSL::Error
        # Connection reset: also acceptable.
      end
      ssl.close rescue nil
      server.close(1.second)
    end
  end

  it "refuses servers that do not negotiate h2" do
    require_openssl!
    HTTP2Spec.bounded do
      tcp = TCPServer.new("127.0.0.1", 0)
      context = TLSFixture.server_context("http/1.1")
      spawn do
        while client = tcp.accept?
          begin
            ssl = OpenSSL::SSL::Socket::Server.new(client, context, sync_close: true)
            ssl.read(Bytes.new(16)) rescue nil
            ssl.close rescue nil
          rescue
            client.close rescue nil
          end
        end
      end
      client = HTTP2::Client.new("127.0.0.1", tcp.local_address.port, TLSFixture.client_context)
      error = expect_raises(HTTP2::ConnectionClosedError) { client.get("/") }
      error.code.should eq(HTTP2::ErrorCode::HTTP_1_1_REQUIRED)
      tcp.close
    end
  end
end
