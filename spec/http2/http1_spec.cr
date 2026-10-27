require "./support"
require "http/client"

private alias TLSFixture = HTTP2Spec::TLSFixture

# HTTP/2 handler answers "h2 <path>", HTTP/1.1 handler "h1 <path>".
private def dual_server
  server = HTTP2::Server.new do |ctx|
    body = ctx.request.body.gets_to_end
    ctx.response.headers["content-type"] = "text/plain"
    ctx.response.print "h2 #{ctx.request.path}#{body.empty? ? "" : " #{body}"}"
  end
  server.http1_handler = HTTP::Handler::HandlerProc.new do |ctx|
    ctx.response.content_type = "text/plain"
    ctx.response.print "h1 #{ctx.request.resource}"
  end
  server
end

private def with_listening(server : HTTP2::Server, &)
  address = server.bind_tcp("127.0.0.1", 0)
  done = Channel(Nil).new(1)
  spawn { server.listen; done.send(nil) }
  begin
    yield address
  ensure
    server.close(1.second) unless server.closed?
    HTTP2Spec.receive(done, what: "server to stop")
  end
end

private def upgrade_request(path : String, settings : String = HTTP2::H2C.encode_settings(HTTP2::Settings.new),
                            method = "GET", body = "", extra = "") : String
  String.build do |io|
    io << method << ' ' << path << " HTTP/1.1\r\n"
    io << "Host: example.com\r\n"
    io << "Connection: Upgrade, HTTP2-Settings\r\n"
    io << "Upgrade: h2c\r\n"
    io << "HTTP2-Settings: " << settings << "\r\n"
    io << "Content-Length: " << body.bytesize << "\r\n" unless body.empty?
    io << extra
    io << "\r\n" << body
  end
end

# Reads an HTTP/1.1 response head; returns the status line and headers.
private def read_head(io : IO) : {String, HTTP::Headers}
  status = io.gets(chomp: true) || raise "EOF before status line"
  headers = HTTP::Headers.new
  while (line = io.gets(chomp: true)) && !line.empty?
    name, value = line.split(':', 2)
    headers.add(name, value.strip)
  end
  {status, headers}
end

describe "HTTP2::Server HTTP/1.1 support" do
  it "serves HTTP/1.1 and HTTP/2 on the same port" do
    HTTP2Spec.bounded do
      server = dual_server
      with_listening(server) do |address|
        h1 = HTTP::Client.new("127.0.0.1", address.port)
        h1.get("/one?x=1").body.should eq("h1 /one?x=1")
        h1.close
        h2 = HTTP2::Client.new("127.0.0.1", address.port)
        h2.get("/two").body_text.should eq("h2 /two")
        h2.close
      end
    end
  end

  it "keeps HTTP/1.1 connections alive" do
    HTTP2Spec.bounded do
      server = dual_server
      ports = Channel(String).new(10)
      server.http1_handler = HTTP::Handler::HandlerProc.new do |ctx|
        ports.send(ctx.request.remote_address.to_s)
        ctx.response.print "ok"
      end
      with_listening(server) do |address|
        client = HTTP::Client.new("127.0.0.1", address.port)
        3.times { client.get("/").body.should eq("ok") }
        client.close
        Array.new(3) { HTTP2Spec.receive(ports) }.uniq.size.should eq(1)
      end
    end
  end

  it "streams request and response bodies without buffering them" do
    HTTP2Spec.bounded do
      server = dual_server
      server.http1_handler = HTTP::Handler::HandlerProc.new do |ctx|
        ctx.response.headers["content-type"] = "application/octet-stream"
        buffer = Bytes.new(64)
        while (read = ctx.request.body.not_nil!.read(buffer)) > 0
          ctx.response.write(buffer[0, read])
          ctx.response.flush
        end
        # Anything can follow the data, e.g. gRPC-Web trailers.
        ctx.response.print "trailer:done"
      end
      with_listening(server) do |address|
        socket = TCPSocket.new("127.0.0.1", address.port)
        socket << "POST /stream HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n"
        socket << "5\r\nhello\r\n"
        socket.flush
        HTTP::Client::Response.from_io(socket) do |response|
          response.status_code.should eq(200)
          response.headers["Transfer-Encoding"].should eq("chunked")
          body = response.body_io
          echo = Bytes.new(5)
          body.read_fully(echo)
          String.new(echo).should eq("hello")
          # The first chunk was echoed before the request body was complete.
          socket << "6\r\n world\r\n0\r\n\r\n"
          socket.flush
          body.gets_to_end.should eq(" worldtrailer:done")
        end
        socket.close
      end
    end
  end

  it "detects an HTTP/2 preface that arrives one byte at a time" do
    HTTP2Spec.bounded do
      server = dual_server
      with_listening(server) do |address|
        socket = TCPSocket.new("127.0.0.1", address.port)
        HTTP2::Connection::CLIENT_PREFACE.each do |byte|
          socket.write_byte(byte)
          socket.flush
          sleep 1.millisecond
        end
        peer = HTTP2Spec::RawPeer.new(socket)
        # The preface was sent already; exchange SETTINGS.
        peer.server_handshake
        peer.send_headers(1, peer.request_fields("GET", "/slow"), end_stream: true)
        peer.read_message(1)[1].should eq("h2 /slow")
        peer.close
      end
    end
  end

  it "upgrades to HTTP/2 with h2c and serves the request as stream 1" do
    HTTP2Spec.bounded do
      server = dual_server
      with_listening(server) do |address|
        socket = TCPSocket.new("127.0.0.1", address.port)
        socket << upgrade_request("/up?q=1")
        socket.flush
        status, headers = read_head(socket)
        status.should eq("HTTP/1.1 101 Switching Protocols")
        headers["Upgrade"].should eq("h2c")
        headers["Connection"].should eq("Upgrade")
        peer = HTTP2Spec::RawPeer.new(socket)
        peer.handshake
        response, body, _ = peer.read_message(1)
        response.should contain({":status", "200"})
        body.should eq("h2 /up?q=1")
        # Further requests use the HTTP/2 connection.
        peer.send_headers(3, peer.request_fields("GET", "/next"), end_stream: true)
        peer.read_message(3)[1].should eq("h2 /next")
        peer.close
      end
    end
  end

  it "delivers the body of an h2c upgrade request on stream 1" do
    HTTP2Spec.bounded do
      server = dual_server
      with_listening(server) do |address|
        socket = TCPSocket.new("127.0.0.1", address.port)
        socket << upgrade_request("/post", method: "POST", body: "payload")
        socket.flush
        read_head(socket)[0].should contain("101")
        peer = HTTP2Spec::RawPeer.new(socket)
        peer.handshake
        peer.read_message(1)[1].should eq("h2 /post payload")
        peer.close
      end
    end
  end

  it "applies the settings of the HTTP2-Settings header" do
    HTTP2Spec.bounded do
      server = HTTP2::Server.new { |ctx| ctx.response.write(Bytes.new(100, 'a'.ord.to_u8)) }
      server.http1_handler = HTTP::Handler::HandlerProc.new { |ctx| ctx.response.print "h1" }
      with_listening(server) do |address|
        socket = TCPSocket.new("127.0.0.1", address.port)
        settings = HTTP2::H2C.encode_settings(HTTP2::Settings.new(initial_window_size: 10_u32))
        socket << upgrade_request("/", settings)
        socket.flush
        read_head(socket)[0].should contain("101")
        peer = HTTP2Spec::RawPeer.new(socket)
        peer.handshake([{4_u16, 10_u32}])
        peer.expect_headers(1)
        peer.expect(HTTP2::DataFrame).data.size.should eq(10)
        peer.close
      end
    end
  end

  it "serves invalid upgrade requests over HTTP/1.1" do
    HTTP2Spec.bounded do
      server = dual_server
      with_listening(server) do |address|
        {upgrade_request("/bad-settings", "!!!"),
         upgrade_request("/odd-settings", Base64.urlsafe_encode(Bytes[0, 1, 0], padding: false)),
         upgrade_request("/bad-value", HTTP2::H2C.encode_settings(HTTP2::Settings.new(max_frame_size: 1_u32))),
         upgrade_request("/two", extra: "HTTP2-Settings: AAA\r\n"),
         "GET /no-connection HTTP/1.1\r\nHost: x\r\nUpgrade: h2c\r\nHTTP2-Settings: \r\n\r\n",
         upgrade_request("/large", method: "POST", body: "x" * 70_000)}.each do |request|
          socket = TCPSocket.new("127.0.0.1", address.port)
          socket << request
          socket.flush
          response = HTTP::Client::Response.from_io(socket)
          response.status_code.should eq(200)
          response.body.should start_with("h1 /")
          socket.close
        end
      end
    end
  end

  it "does not upgrade when h2c_upgrade is disabled" do
    HTTP2Spec.bounded do
      server = dual_server
      server.h2c_upgrade = false
      with_listening(server) do |address|
        socket = TCPSocket.new("127.0.0.1", address.port)
        socket << upgrade_request("/plain")
        socket.flush
        HTTP::Client::Response.from_io(socket).body.should eq("h1 /plain")
        socket.close
      end
    end
  end

  it "rejects HTTP/1.1 without an http1_handler" do
    HTTP2Spec.bounded do
      server = HTTP2::Server.new { |ctx| ctx.response.print "h2" }
      HTTP2Spec.with_raw_client(server) do |peer|
        peer.send_raw("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".to_slice)
        peer.expect(HTTP2::SettingsFrame)
        peer.expect_goaway(HTTP2::ErrorCode::PROTOCOL_ERROR)
      end
    end
  end

  it "closes idle keep-alive connections and lets busy ones finish on close" do
    HTTP2Spec.bounded do
      server = dual_server
      started = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      server.http1_handler = HTTP::Handler::HandlerProc.new do |ctx|
        if ctx.request.path == "/slow"
          started.send(nil)
          HTTP2Spec.receive(release)
        end
        ctx.response.print "done"
      end
      address = server.bind_tcp("127.0.0.1", 0)
      done = Channel(Nil).new(1)
      spawn { server.listen; done.send(nil) }

      idle = HTTP::Client.new("127.0.0.1", address.port)
      idle.get("/").body.should eq("done")
      busy = TCPSocket.new("127.0.0.1", address.port)
      busy << "GET /slow HTTP/1.1\r\nHost: x\r\n\r\n"
      busy.flush
      HTTP2Spec.receive(started)

      closed = Channel(Nil).new(1)
      spawn { server.close(5.seconds); closed.send(nil) }
      sleep 50.milliseconds
      release.send(nil)
      response = HTTP::Client::Response.from_io(busy)
      response.body.should eq("done")
      busy.gets.should be_nil
      HTTP2Spec.receive(closed)
      HTTP2Spec.receive(done)
      busy.close
      idle.close
    end
  end

  describe "TLS" do
    it "negotiates http/1.1 or h2 via ALPN and detects clients without ALPN" do
      pending!("openssl CLI not available") unless TLSFixture.paths
      HTTP2Spec.bounded(30.seconds) do
        server = dual_server
        server.alpn_protocols.should eq(["h2", "http/1.1"])
        address = server.bind_tls("127.0.0.1", 0, TLSFixture.server_context)
        done = Channel(Nil).new(1)
        spawn { server.listen; done.send(nil) }
        begin
          h1 = HTTP::Client.new("127.0.0.1", address.port, tls: TLSFixture.client_context("http/1.1"))
          h1.get("/alpn").body.should eq("h1 /alpn")
          h1.close

          plain = HTTP::Client.new("127.0.0.1", address.port, tls: TLSFixture.client_context)
          plain.get("/none").body.should eq("h1 /none")
          plain.close

          h2 = HTTP2::Client.new("127.0.0.1", address.port, TLSFixture.client_context)
          h2.get("/h2").body_text.should eq("h2 /h2")
          h2.close
        ensure
          server.close(1.second)
          HTTP2Spec.receive(done)
        end
      end
    end

    it "only advertises h2 without an http1_handler" do
      HTTP2::Server.new { }.alpn_protocols.should eq(["h2"])
    end
  end
end
