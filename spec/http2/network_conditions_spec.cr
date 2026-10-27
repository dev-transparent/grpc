require "./support"
require "../support/fault_proxy"

private def echo_server(opts = HTTP2::Server.default_options)
  HTTP2::Server.new(HTTP2::Server.default_settings, options: opts) do |ctx|
    IO.copy(ctx.request.body, ctx.response)
  end
end

# Runs *server* behind a fault proxy and yields the proxy and a client
# connected through it.
private def through_proxy(server : HTTP2::Server, client_options = HTTP2::Client.default_options, &)
  address = server.bind_tcp("127.0.0.1", 0)
  done = Channel(Nil).new(1)
  spawn { server.listen; done.send(nil) }
  proxy = FaultProxy.new("127.0.0.1", address.port)
  client = HTTP2::Client.new("127.0.0.1", proxy.port, options: client_options)
  begin
    yield proxy, client
  ensure
    proxy.close
    HTTP2Spec.within(5.seconds, "client close") { client.close } rescue nil
    server.close(1.second)
    HTTP2Spec.receive(done, what: "server to stop")
  end
end

private def payload(size : Int32) : Bytes
  HTTP2Spec.random_bytes(size, Random.new(size))
end

describe "HTTP2 under adverse network conditions" do
  it "transfers large bodies delivered one byte at a time in both directions" do
    HTTP2Spec.bounded(60.seconds) do
      through_proxy(echo_server) do |proxy, client|
        proxy.upstream.chunk_size = 1
        proxy.downstream.chunk_size = 1
        body = payload(40_000)
        response = client.post("/", body: body)
        response.body.gets_to_end.to_slice.should eq(body)
      end
    end
  end

  it "detects the HTTP/2 preface and serves HTTP/1.1 when data arrives byte by byte" do
    HTTP2Spec.bounded(30.seconds) do
      server = echo_server
      server.http1_handler = HTTP::Handler::HandlerProc.new { |ctx| ctx.response.print "h1" }
      through_proxy(server) do |proxy, client|
        proxy.upstream.chunk_size = 1
        client.post("/", body: "hello").body_text.should eq("hello")
        socket = TCPSocket.new("127.0.0.1", proxy.port)
        socket << "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        socket.flush
        HTTP::Client::Response.from_io(socket).body.should eq("h1")
        socket.close
      end
    end
  end

  it "completes concurrent streams over a slow, high latency link" do
    HTTP2Spec.bounded(60.seconds) do
      through_proxy(echo_server) do |proxy, client|
        {proxy.upstream, proxy.downstream}.each do |direction|
          direction.latency = 50.milliseconds
          direction.bandwidth = 400_000
          direction.chunk_size = 1_000
        end
        started = Time.instant
        results = Channel(Bool | Exception).new(4)
        4.times do |i|
          spawn do
            body = payload(50_000 + i)
            results.send(client.post("/#{i}", body: body).body.gets_to_end.to_slice == body)
          rescue e
            results.send(e)
          end
        end
        4.times do
          result = HTTP2Spec.receive(results, 30.seconds)
          raise result if result.is_a?(Exception)
          result.should be_true
        end
        # 200 kB each way at 400 kB/s plus latency.
        (Time.instant - started).should be >= 500.milliseconds
      end
    end
  end

  it "detects a stalled server with client keepalive" do
    HTTP2Spec.bounded(30.seconds) do
      opts = HTTP2::ConnectionOptions.new(keepalive_time: 100.milliseconds, keepalive_timeout: 300.milliseconds)
      server = HTTP2::Server.new { |ctx| ctx.request.body.gets_to_end }
      through_proxy(server, opts) do |proxy, client|
        stream = client.open_stream("POST", "/")
        stream.send_data("partial".to_slice)
        sleep 50.milliseconds
        proxy.pause
        started = Time.instant
        expect_raises(HTTP2::ConnectionClosedError, /Keepalive/) { stream.headers }
        (Time.instant - started).should be < 2.seconds
        proxy.resume
        proxy.drop_connections
        # The client recovers on a new connection.
        proxy.reset
        client.post("/", body: "x").status.should eq(200)
      end
    end
  end

  it "detects a stalled client with server keepalive" do
    HTTP2Spec.bounded(30.seconds) do
      failed = Channel(Exception).new(1)
      opts = HTTP2::ConnectionOptions.new(keepalive_time: 100.milliseconds, keepalive_timeout: 300.milliseconds)
      server = HTTP2::Server.new(HTTP2::Server.default_settings, options: opts) do |ctx|
        ctx.request.body.gets_to_end
      rescue e
        failed.send(e)
      end
      through_proxy(server) do |proxy, client|
        stream = client.open_stream("POST", "/")
        stream.send_data("partial".to_slice)
        sleep 50.milliseconds
        proxy.pause
        HTTP2Spec.receive(failed, 3.seconds).should be_a(HTTP2::ConnectionClosedError)
        proxy.resume
      end
    end
  end

  it "fails all streams when the connection is dropped and reconnects" do
    HTTP2Spec.bounded(30.seconds) do
      server = HTTP2::Server.new { |ctx| ctx.request.body.gets_to_end }
      through_proxy(server) do |proxy, client|
        streams = Array.new(5) do
          stream = client.open_stream("POST", "/")
          stream.send_data("x".to_slice)
          stream
        end
        HTTP2Spec.eventually { proxy.connections == 1 }
        sleep 50.milliseconds
        proxy.drop_connections(rst: true)
        streams.each do |stream|
          expect_raises(HTTP2::ConnectionClosedError) { stream.headers }
        end
        HTTP2Spec.eventually { client.connection.active_streams == 0 }
        client.post("/", body: "after").status.should eq(200)
        proxy.accepted.should eq(2)
      end
    end
  end

  it "fails requests to a black-holed server instead of hanging" do
    HTTP2Spec.bounded(30.seconds) do
      server = HTTP2::Server.new { |ctx| ctx.response.print "ok" }
      opts = HTTP2::ConnectionOptions.new(settings_timeout: 300.milliseconds)
      through_proxy(server, opts) do |proxy, client|
        proxy.black_hole_connections = true
        started = Time.instant
        expect_raises(HTTP2::ConnectionClosedError, /SETTINGS_TIMEOUT/) { client.get("/") }
        (Time.instant - started).should be < 3.seconds
        proxy.black_hole_connections = false
        client.get("/").body_text.should eq("ok")
      end
    end
  end

  it "fails requests whose responses are black-holed when keepalive is enabled" do
    HTTP2Spec.bounded(30.seconds) do
      server = HTTP2::Server.new { |ctx| ctx.response.print "ok" }
      opts = HTTP2::ConnectionOptions.new(keepalive_time: 100.milliseconds, keepalive_timeout: 200.milliseconds)
      through_proxy(server, opts) do |proxy, client|
        client.get("/").body_text.should eq("ok")
        proxy.downstream.black_hole = true
        expect_raises(HTTP2::ConnectionClosedError, /Keepalive/) { client.get("/") }
        proxy.downstream.black_hole = false
        client.get("/").body_text.should eq("ok")
      end
    end
  end

  describe FaultProxy do
    it "resets connections abruptly" do
      HTTP2Spec.bounded do
        server = TCPServer.new("127.0.0.1", 0)
        spawn { while socket = server.accept?
          spawn { IO.copy(socket, socket) rescue nil }
        end }
        proxy = FaultProxy.new("127.0.0.1", server.local_address.port)
        socket = TCPSocket.new("127.0.0.1", proxy.port)
        socket << "ping"
        socket.flush
        buffer = Bytes.new(4)
        socket.read_fully(buffer)
        String.new(buffer).should eq("ping")
        proxy.drop_connections(rst: true)
        expect_raises(IO::Error) do
          loop do
            break if socket.read(buffer) == 0
          end
          raise IO::Error.new("EOF instead of reset")
        end
        proxy.close
        server.close
      end
    end

    it "adds latency without limiting throughput" do
      HTTP2Spec.bounded do
        server = TCPServer.new("127.0.0.1", 0)
        spawn { while socket = server.accept?
          spawn { IO.copy(socket, socket) rescue nil }
        end }
        proxy = FaultProxy.new("127.0.0.1", server.local_address.port)
        proxy.upstream.latency = 100.milliseconds
        socket = TCPSocket.new("127.0.0.1", proxy.port)
        started = Time.instant
        10.times { socket << "x"; socket.flush; sleep 5.milliseconds }
        buffer = Bytes.new(10)
        socket.read_fully(buffer)
        elapsed = Time.instant - started
        elapsed.should be >= 100.milliseconds
        elapsed.should be < 400.milliseconds
        proxy.close
        server.close
      end
    end
  end
end
