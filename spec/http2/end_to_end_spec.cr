require "./support"
require "digest/sha256"
require "http/status"

private alias EC = HTTP2::ErrorCode

private LARGE = HTTP2Spec.random_bytes(8 * 1024 * 1024, Random.new(7))

private def serve(server : HTTP2::Server, client_settings = HTTP2::Client.default_settings,
                  timeout = 30.seconds, &block : HTTP2::Client, Socket::IPAddress ->)
  HTTP2Spec.bounded(timeout) do
    HTTP2Spec.with_server(server, client_settings) { |client, address| block.call(client, address) }
  end
end

private def sha256(data : Bytes) : String
  Digest::SHA256.hexdigest(data)
end

private def read_all(io : IO) : Bytes
  memory = IO::Memory.new
  IO.copy(io, memory)
  memory.to_slice
end

# Echoes the request body back as it arrives, flushing after every read.
private def streaming_echo_server(settings = HTTP2::Server.default_settings, window = 16_777_216)
  HTTP2::Server.new(settings, window) do |ctx|
    buffer = Bytes.new(32_768)
    while (count = ctx.request.body.read(buffer)) > 0
      ctx.response.write(buffer[0, count])
      ctx.response.flush
    end
  end
end

private def silence_server_log(&)
  HTTP2::Server::Log.level = ::Log::Severity::None
  yield
ensure
  HTTP2::Server::Log.level = ::Log::Severity::Info
end

private class PathHandler
  include HTTP2::Server::Handler

  def call(context : HTTP2::Server::Context)
    context.response.status = HTTP::Status::ACCEPTED
    context.response.print "handler #{context.request.resource_path}"
  end
end

describe "HTTP2 end to end" do
  describe "requests" do
    it "performs a GET request" do
      server = HTTP2::Server.new do |ctx|
        ctx.response.headers["content-type"] = "text/plain"
        ctx.response.headers["x-method"] = ctx.request.method
        ctx.response.headers["x-scheme"] = ctx.request.scheme
        ctx.response.headers["x-authority"] = ctx.request.authority.to_s
        ctx.response.headers["x-agent"] = ctx.request.headers["user-agent"]? || "none"
        ctx.response.print "hello #{ctx.request.path}"
      end
      serve(server) do |client, address|
        response = client.get("/hello?x=1", HTTP::Headers{"User-Agent" => "spec"})
        response.status.should eq(200)
        response.success?.should be_true
        response.headers["content-type"].should eq("text/plain")
        response.headers["x-method"].should eq("GET")
        response.headers["x-scheme"].should eq("http")
        response.headers["x-authority"].should eq("127.0.0.1:#{address.port}")
        response.headers["x-agent"].should eq("spec")
        response.body_text.should eq("hello /hello?x=1")
        response.trailers.should be_nil
      end
    end

    it "performs POST, PUT and PATCH requests with String, Bytes and IO bodies" do
      server = HTTP2::Server.new do |ctx|
        ctx.response.print "#{ctx.request.method}:#{ctx.request.body.gets_to_end}"
      end
      serve(server) do |client, _|
        client.post("/", body: "string body").body_text.should eq("POST:string body")
        client.put("/", body: "bytes body".to_slice).body_text.should eq("PUT:bytes body")
        client.patch("/", body: IO::Memory.new("io body")).body_text.should eq("PATCH:io body")
        client.post("/", body: "").body_text.should eq("POST:")
        client.delete("/").body_text.should eq("DELETE:")
        client.options("/").body_text.should eq("OPTIONS:")
      end
    end

    it "handles HEAD requests with a content-length but no body" do
      server = HTTP2::Server.new do |ctx|
        ctx.response.headers["content-length"] = "1234"
      end
      serve(server) do |client, _|
        response = client.head("/")
        response.status.should eq(200)
        response.headers["content-length"].should eq("1234")
        response.body_text.should eq("")
      end
    end

    it "supports Handler instances and custom statuses" do
      serve(HTTP2::Server.new(PathHandler.new)) do |client, _|
        response = client.get("/some/path?query")
        response.status.should eq(202)
        response.body_text.should eq("handler /some/path")
      end
    end

    it "responds with 500 when the handler raises" do
      server = HTTP2::Server.new { |_| raise "boom" }
      silence_server_log do
        serve(server) do |client, _|
          response = client.get("/")
          response.status.should eq(500)
          response.success?.should be_false
          response.body_text.should eq("")
        end
      end
    end

    it "sends many sequential requests on one connection" do
      server = HTTP2::Server.new { |ctx| ctx.response.print ctx.request.path }
      serve(server) do |client, _|
        connection = client.connection
        300.times do |i|
          client.get("/#{i}").body_text.should eq("/#{i}")
        end
        client.connection.should be(connection)
      end
    end

    it "transfers headers larger than the frame size using CONTINUATION" do
      big = "h" * 50_000
      server = HTTP2::Server.new do |ctx|
        ctx.response.headers["x-echo"] = ctx.request.headers["x-big"]
      end
      serve(server) do |client, _|
        response = client.get("/", HTTP::Headers{"x-big" => big})
        response.headers["x-echo"].should eq(big)
      end
    end

    it "works over a UNIX socket" do
      path = File.tempname("http2-spec", ".sock")
      server = HTTP2::Server.new { |ctx| ctx.response.print "unix #{ctx.request.path}" }
      server.bind_unix(path)
      HTTP2Spec.bounded do
        done = Channel(Nil).new(1)
        spawn { server.listen; done.send(nil) }
        client = HTTP2::Client.new("localhost") { UNIXSocket.new(path).as(IO) }
        client.get("/sock").body_text.should eq("unix /sock")
        client.close
        server.close
        HTTP2Spec.receive(done)
      end
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end

  describe "large bodies and flow control" do
    it "receives a large response body" do
      server = HTTP2::Server.new do |ctx|
        offset = 0
        while offset < LARGE.size
          count = Math.min(100_000, LARGE.size - offset)
          ctx.response.write(LARGE[offset, count])
          offset += count
        end
      end
      serve(server) do |client, _|
        body = read_all(client.get("/").body)
        body.size.should eq(LARGE.size)
        sha256(body).should eq(sha256(LARGE))
      end
    end

    it "sends a large request body" do
      server = HTTP2::Server.new do |ctx|
        body = read_all(ctx.request.body)
        ctx.response.print "#{body.size}:#{sha256(body)}"
      end
      serve(server) do |client, _|
        client.post("/", body: LARGE).body_text.should eq("#{LARGE.size}:#{sha256(LARGE)}")
      end
    end

    it "streams large bodies in both directions at once" do
      serve(streaming_echo_server) do |client, _|
        data = LARGE[0, 4 * 1024 * 1024]
        stream = client.open_stream("POST", "/echo")
        spawn do
          offset = 0
          while offset < data.size
            count = Math.min(50_000, data.size - offset)
            stream.send_data(data[offset, count])
            offset += count
          end
          stream.close_send
        end
        response = HTTP2::Client::Response.new(stream)
        echoed = read_all(response.body)
        echoed.size.should eq(data.size)
        (echoed == data).should be_true
      end
    end

    it "streams large bodies with minimal flow control windows" do
      settings = HTTP2::Settings.new(initial_window_size: 65_535_u32, max_concurrent_streams: 100_u32)
      client_settings = HTTP2::Settings.new(enable_push: false, initial_window_size: 65_535_u32)
      server = streaming_echo_server(settings, 65_535)
      HTTP2Spec.bounded(30.seconds) do
        address = server.bind_tcp("127.0.0.1", 0)
        spawn { server.listen }
        client = HTTP2::Client.new("127.0.0.1", address.port, local_settings: client_settings, connection_window_size: 65_535)
        data = LARGE[0, 2 * 1024 * 1024]
        stream = client.open_stream("POST", "/echo")
        spawn do
          stream.send_data(data)
          stream.close_send
        end
        response = HTTP2::Client::Response.new(stream)
        echoed = read_all(response.body)
        (echoed == data).should be_true
        client.close
        server.close
      end
    end

    it "transfers large bodies on many concurrent streams" do
      serve(streaming_echo_server) do |client, _|
        results = Channel(Bool | Exception).new(20)
        20.times do |i|
          spawn do
            data = LARGE[i * 300_000, 256 * 1024]
            stream = client.open_stream("POST", "/#{i}")
            spawn do
              stream.send_data(data)
              stream.close_send
            end
            results.send(read_all(HTTP2::Client::Response.new(stream).body) == data)
          rescue ex
            results.send(ex)
          end
        end
        20.times do
          result = HTTP2Spec.receive(results, 20.seconds)
          raise result if result.is_a?(Exception)
          result.should be_true
        end
      end
    end
  end

  describe "multiplexing" do
    it "multiplexes many concurrent streams over one connection" do
      connections = Set(UInt64).new
      server = HTTP2::Server.new do |ctx|
        connections << ctx.stream.connection.object_id
        sleep 1.millisecond
        ctx.response.print "#{ctx.request.path}:#{ctx.stream.id}"
      end
      serve(server) do |client, _|
        count = 250 # more than the server's SETTINGS_MAX_CONCURRENT_STREAMS
        results = Channel(String | Exception).new(count)
        count.times do |i|
          spawn do
            results.send(client.get("/#{i}").body_text)
          rescue ex
            results.send(ex)
          end
        end
        bodies = Array.new(count) do
          result = HTTP2Spec.receive(results, 20.seconds)
          raise result if result.is_a?(Exception)
          result
        end
        paths = bodies.map(&.split(':')[0]).sort
        paths.should eq((0...count).map { |i| "/#{i}" }.sort)
        bodies.map(&.split(':')[1].to_i).uniq.size.should eq(count)
        connections.size.should eq(1)
      end
    end

    it "keeps slow streams from blocking others" do
      release = Channel(Nil).new(1)
      server = HTTP2::Server.new do |ctx|
        HTTP2Spec.receive(release) if ctx.request.path == "/slow"
        ctx.response.print ctx.request.path
      end
      serve(server) do |client, _|
        slow = Channel(String).new(1)
        spawn { slow.send(client.get("/slow").body_text) }
        5.times { |i| client.get("/fast#{i}").body_text.should eq("/fast#{i}") }
        release.send(nil)
        HTTP2Spec.receive(slow).should eq("/slow")
      end
    end
  end

  describe "trailers" do
    it "sends and receives trailers in both directions" do
      server = HTTP2::Server.new do |ctx|
        body = ctx.request.body.gets_to_end
        trailers = ctx.request.trailers.not_nil!
        ctx.response.headers["content-type"] = "text/plain"
        ctx.response.print body.upcase
        ctx.response.trailers["x-request-trailer"] = trailers["x-checksum"]
        ctx.response.trailers["x-status"] = "done"
      end
      serve(server) do |client, _|
        stream = client.open_stream("POST", "/", HTTP::Headers{"content-type" => "text/plain"})
        stream.send_data("hello ".to_slice)
        stream.send_data("trailers".to_slice)
        stream.send_trailers([{"x-checksum", "abc123"}])
        response = HTTP2::Client::Response.new(stream)
        response.headers["content-type"].should eq("text/plain")
        response.body_text.should eq("HELLO TRAILERS")
        trailers = response.trailers.not_nil!
        trailers["x-request-trailer"].should eq("abc123")
        trailers["x-status"].should eq("done")
      end
    end

    it "sends trailers without a body" do
      server = HTTP2::Server.new do |ctx|
        ctx.response.trailers["grpc-status"] = "0"
      end
      serve(server) do |client, _|
        response = client.get("/")
        response.body_text.should eq("")
        response.trailers.not_nil!["grpc-status"].should eq("0")
      end
    end
  end

  describe "streaming" do
    it "interleaves request and response messages on one stream" do
      serve(streaming_echo_server) do |client, _|
        stream = client.open_stream("POST", "/chat")
        stream.send_data("hello".to_slice)
        response = HTTP2::Client::Response.new(stream)
        buffer = Bytes.new(5)
        response.body.read_fully(buffer)
        String.new(buffer).should eq("hello")
        50.times do |i|
          message = "message #{i}".to_slice
          stream.send_data(message)
          echoed = Bytes.new(message.size)
          response.body.read_fully(echoed)
          echoed.should eq(message)
        end
        stream.close_send
        response.body_text.should eq("")
        stream.wait_closed(5.seconds).should be_true
      end
    end
  end

  describe "cancellation" do
    it "propagates a client reset to the server handler" do
      result = Channel(Exception?).new(1)
      received = Channel(Nil).new(1)
      server = HTTP2::Server.new do |ctx|
        begin
          ctx.request.body.read(Bytes.new(10))
          received.send(nil)
          ctx.request.body.gets_to_end
          result.send(nil)
        rescue ex
          result.send(ex)
        end
      end
      serve(server) do |client, _|
        stream = client.open_stream("POST", "/")
        stream.send_data("x".to_slice)
        HTTP2Spec.receive(received)
        stream.reset(EC::CANCEL)
        error = HTTP2Spec.receive(result).as(HTTP2::StreamResetError)
        error.code.should eq(EC::CANCEL)
        error.remote?.should be_true
        stream.reset?.should be_true
        local = expect_raises(HTTP2::StreamResetError) { stream.body.gets_to_end }
        local.remote?.should be_false
        # The connection is still usable.
        client.post("/", body: "after").status.should eq(200)
      end
    end

    it "stops a server that is blocked on flow control when the client cancels" do
      result = Channel(Exception?).new(1)
      server = HTTP2::Server.new do |ctx|
        begin
          loop { ctx.response.write(LARGE[0, 65_536]) }
        rescue ex
          result.send(ex)
        end
      end
      serve(server) do |client, _|
        response = client.get("/infinite")
        response.body.read_fully(Bytes.new(100_000))
        response.stream.reset(EC::CANCEL)
        error = HTTP2Spec.receive(result).as(HTTP2::StreamResetError)
        error.code.should eq(EC::CANCEL)
        client.get("/").status.should eq(200)
      end
    end

    it "propagates a server reset to the client" do
      server = HTTP2::Server.new do |ctx|
        ctx.response.print "partial"
        ctx.response.flush
        ctx.stream.reset(EC::ENHANCE_YOUR_CALM)
      end
      serve(server) do |client, _|
        response = client.get("/")
        response.status.should eq(200)
        error = expect_raises(HTTP2::StreamResetError) { response.body_text }
        error.code.should eq(EC::ENHANCE_YOUR_CALM)
        error.remote?.should be_true
        client.get("/").status.should eq(200)
      end
    end

    it "keeps an early complete response when the server stops the request body with NO_ERROR" do
      server = HTTP2::Server.new { |ctx| ctx.response.print "early #{ctx.request.method}" }
      serve(server) do |client, _|
        response = client.post("/", body: LARGE)
        response.status.should eq(200)
        response.body_text.should eq("early POST")
        response = client.put("/", body: IO::Memory.new(LARGE))
        response.body_text.should eq("early PUT")
      end
    end

    it "fails a client blocked on sending when the server resets" do
      server = HTTP2::Server.new do |ctx|
        ctx.request.body.read(Bytes.new(1))
        ctx.stream.reset(EC::REFUSED_STREAM)
      end
      serve(server) do |client, _|
        stream = client.open_stream("POST", "/")
        error = expect_raises(HTTP2::StreamResetError) do
          loop { stream.send_data(LARGE[0, 1_000_000]) }
        end
        error.code.should eq(EC::REFUSED_STREAM)
      end
    end
  end

  describe "connection management" do
    it "pings the server" do
      serve(HTTP2::Server.new { |_| }) do |client, _|
        rtt = client.connection.ping(5.seconds)
        rtt.should be >= Time::Span.zero
        rtt.should be < 5.seconds
      end
    end

    it "reconnects after the client closes its connection" do
      server = HTTP2::Server.new { |ctx| ctx.response.print ctx.stream.connection.object_id }
      serve(server) do |client, _|
        first = client.get("/").body_text
        client.close
        second = client.get("/").body_text
        second.should_not eq(first)
      end
    end

    it "shuts down gracefully, finishing active streams, and the client reconnects" do
      started = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      server_a = HTTP2::Server.new do |ctx|
        if ctx.request.path == "/slow"
          started.send(nil)
          HTTP2Spec.receive(release)
        end
        ctx.response.print "A #{ctx.request.path}"
      end
      server_b = HTTP2::Server.new { |ctx| ctx.response.print "B #{ctx.request.path}" }

      HTTP2Spec.bounded(20.seconds) do
        address = server_a.bind_tcp("127.0.0.1", 0)
        listening_a = Channel(Nil).new(1)
        spawn { server_a.listen; listening_a.send(nil) }
        client = HTTP2::Client.new("127.0.0.1", address.port)

        client.get("/a").body_text.should eq("A /a")
        connection = client.connection

        slow = Channel(String).new(1)
        spawn { slow.send(client.get("/slow").body_text) }
        HTTP2Spec.receive(started)

        closed = Channel(Nil).new(1)
        spawn { server_a.close(5.seconds); closed.send(nil) }
        HTTP2Spec.eventually(what: "GOAWAY") { connection.goaway_received }
        connection.goaway_received.not_nil!.error_code.should eq(EC::NO_ERROR)
        connection.available?.should be_false

        release.send(nil)
        HTTP2Spec.receive(slow).should eq("A /slow")
        HTTP2Spec.receive(closed)
        HTTP2Spec.receive(listening_a)
        server_a.closed?.should be_true
        connection.wait_closed

        server_b.bind_tcp("127.0.0.1", address.port)
        listening_b = Channel(Nil).new(1)
        spawn { server_b.listen; listening_b.send(nil) }
        client.get("/b").body_text.should eq("B /b")
        client.connection.should_not be(connection)

        client.close
        server_b.close
        HTTP2Spec.receive(listening_b)
      end
    end

    it "raises when the server is unreachable" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      server.close
      client = HTTP2::Client.new("127.0.0.1", port)
      expect_raises(Socket::ConnectError) { client.get("/") }
    end

    it "fails in-flight requests when the server connection drops" do
      started = Channel(Nil).new(1)
      server = HTTP2::Server.new do |ctx|
        started.send(nil)
        sleep 10.seconds
      end
      serve(server) do |client, _|
        result = Channel(Exception?).new(1)
        spawn do
          client.get("/").body_text
          result.send(nil)
        rescue ex
          result.send(ex)
        end
        HTTP2Spec.receive(started)
        server.close(100.milliseconds)
        HTTP2Spec.receive(result).should be_a(HTTP2::ConnectionClosedError)
      end
    end
  end
end
