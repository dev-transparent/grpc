require "./support"

private alias EC = HTTP2::ErrorCode

private def options(**args)
  HTTP2::ConnectionOptions.new(**args)
end

private def server_with(opts : HTTP2::ConnectionOptions, &block : HTTP2::Server::Context ->)
  HTTP2::Server.new(block, HTTP2::Server.default_settings, 16_777_216, opts)
end

private def get(peer, id, end_stream = true)
  peer.send_headers(id, peer.request_fields("GET", "/"), end_stream: end_stream)
end

private def ack(peer, ping : HTTP2::PingFrame)
  peer.send(HTTP2::PingFrame.new(ping.data, ack: true))
end

private def ping(peer, byte : Int = 1)
  peer.send(HTTP2::PingFrame.new(Bytes.new(8, byte.to_u8)))
end

# Expects the two-phase graceful GOAWAY, acknowledging the PING.
private def expect_graceful_goaway(peer, last_stream_id : Int, timeout = HTTP2Spec::DEFAULT_TIMEOUT)
  first = peer.expect(HTTP2::GoawayFrame, timeout)
  first.error_code.should eq(EC::NO_ERROR)
  first.last_stream_id.should eq(HTTP2::MAX_STREAM_ID)
  ack(peer, peer.expect(HTTP2::PingFrame))
  final = peer.expect(HTTP2::GoawayFrame)
  final.error_code.should eq(EC::NO_ERROR)
  final.last_stream_id.should eq(last_stream_id.to_u32)
end

# Opens a stream on a client connected to a raw server peer.
private def client_with_peer(opts : HTTP2::ConnectionOptions)
  client, peers = HTTP2Spec.raw_server_client(options: opts)
  connection = client.connection
  peer = HTTP2Spec.receive(peers)
  peer.server_handshake
  {client, connection, peer}
end

describe "HTTP2 keepalive" do
  describe "sender" do
    it "sends PINGs after keepalive_time of inactivity while streams are active" do
      HTTP2Spec.bounded do
        client, connection, peer = client_with_peer(options(keepalive_time: 100.milliseconds, keepalive_timeout: 2.seconds))
        stream = connection.open_stream(peer.request_fields, end_stream: true)
        peer.expect_headers(1)
        last = Time.instant
        3.times do
          ping = peer.expect(HTTP2::PingFrame)
          ping.ack?.should be_false
          now = Time.instant
          (now - last).should be >= 80.milliseconds
          last = now
          ack(peer, ping)
        end
        connection.available?.should be_true
        peer.send_headers(1, [{":status", "200"}], end_stream: true)
        stream.wait_closed(2.seconds).should be_true
        stream.error.should be_nil
        client.close
      end
    end

    it "does not send PINGs without active streams" do
      HTTP2Spec.bounded do
        client, connection, peer = client_with_peer(options(keepalive_time: 50.milliseconds))
        stream = connection.open_stream(peer.request_fields, end_stream: true)
        peer.expect_headers(1)
        peer.send_headers(1, [{":status", "200"}], end_stream: true)
        stream.wait_closed(2.seconds).should be_true
        peer.expect_silence(300.milliseconds)
        client.close
      end
    end

    it "sends PINGs without active streams when keepalive_permit_without_calls is set" do
      HTTP2Spec.bounded do
        client, _, peer = client_with_peer(options(keepalive_time: 50.milliseconds, keepalive_permit_without_calls: true))
        2.times { ack(peer, peer.expect(HTTP2::PingFrame)) }
        client.close
      end
    end

    it "closes the connection and fails all streams when a PING is not acknowledged" do
      HTTP2Spec.bounded do
        _, connection, peer = client_with_peer(options(keepalive_time: 50.milliseconds, keepalive_timeout: 200.milliseconds))
        streams = Array.new(3) { connection.open_stream(peer.request_fields, end_stream: true) }
        3.times { |i| peer.expect_headers(i * 2 + 1) }
        peer.expect(HTTP2::PingFrame)
        started = Time.instant
        streams.each do |stream|
          expect_raises(HTTP2::ConnectionClosedError, /Keepalive/) { stream.headers }
        end
        (Time.instant - started).should be < 2.seconds
        HTTP2Spec.within(2.seconds, "connection close") { connection.wait_closed }
        connection.closed?.should be_true
        peer.expect_closed
      end
    end

    it "is not confused by acknowledgements of other PINGs" do
      HTTP2Spec.bounded do
        _, connection, peer = client_with_peer(options(keepalive_time: 50.milliseconds, keepalive_timeout: 300.milliseconds))
        stream = connection.open_stream(peer.request_fields, end_stream: true)
        peer.expect_headers(1)
        ping = peer.expect(HTTP2::PingFrame)
        peer.send(HTTP2::PingFrame.new(Bytes.new(8, 7_u8), ack: true))
        expect_raises(HTTP2::ConnectionClosedError, /Keepalive/) { stream.headers }
        ping.ack?.should be_false
      end
    end
  end

  describe "enforcement" do
    it "sends GOAWAY(ENHANCE_YOUR_CALM, too_many_pings) after too many PINGs with active streams" do
      release = Channel(Nil).new(1)
      server = server_with(options(min_ping_interval: 1.second)) { HTTP2Spec.receive(release, 10.seconds) rescue nil }
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          get(peer, 1)
          4.times { |i| ping(peer, i) }
          goaway = peer.expect(HTTP2::GoawayFrame)
          goaway.error_code.should eq(EC::ENHANCE_YOUR_CALM)
          String.new(goaway.debug_data).should eq("too_many_pings")
          peer.expect_closed
          release.send(nil)
        end
      end
    end

    it "tolerates up to max_ping_strikes early PINGs" do
      release = Channel(Nil).new(1)
      server = server_with(options(min_ping_interval: 1.second)) { HTTP2Spec.receive(release, 10.seconds) rescue nil }
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          get(peer, 1)
          3.times { |i| ping(peer, i) }
          peer.expect_silence(200.milliseconds)
          release.send(nil)
        end
      end
    end

    it "accepts PINGs that respect min_ping_interval" do
      release = Channel(Nil).new(1)
      server = server_with(options(min_ping_interval: 100.milliseconds)) { HTTP2Spec.receive(release, 10.seconds) rescue nil }
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          get(peer, 1)
          6.times do |i|
            ping(peer, i)
            peer.expect(HTTP2::PingFrame).ack?.should be_true
            sleep 130.milliseconds
          end
          peer.expect_silence(50.milliseconds)
          release.send(nil)
        end
      end
    end

    it "counts PINGs without active streams as strikes unless permit_without_stream" do
      server = server_with(options(min_ping_interval: 10.milliseconds)) { }
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          4.times do |i|
            ping(peer, i)
            sleep 30.milliseconds
          end
          goaway = peer.expect(HTTP2::GoawayFrame)
          goaway.error_code.should eq(EC::ENHANCE_YOUR_CALM)
          String.new(goaway.debug_data).should eq("too_many_pings")
        end
      end
    end

    it "accepts PINGs without active streams when permit_without_stream is set" do
      server = server_with(options(min_ping_interval: 10.milliseconds, permit_without_stream: true)) { }
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          6.times do |i|
            ping(peer, i)
            peer.expect(HTTP2::PingFrame).ack?.should be_true
            sleep 30.milliseconds
          end
          peer.expect_silence(50.milliseconds)
        end
      end
    end

    it "resets strikes while sending DATA" do
      server = server_with(options(min_ping_interval: 10.seconds)) do |ctx|
        10.times do
          ctx.response.print "chunk"
          ctx.response.flush
          sleep 20.milliseconds
        end
      end
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          get(peer, 1)
          peer.expect_headers(1)
          received = 0
          loop do
            frame = peer.expect(HTTP2::DataFrame)
            received += frame.data.size
            break if frame.end_stream?
            ping(peer, received)
          end
          received.should eq(50)
          peer.expect_silence(100.milliseconds)
        end
      end
    end

    it "is disabled without min_ping_interval" do
      server = server_with(options) { }
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          10.times { |i| ping(peer, i) }
          10.times { peer.expect(HTTP2::PingFrame).ack?.should be_true }
          peer.expect_silence(50.milliseconds)
        end
      end
    end

    it "makes the client back off its keepalive time after too_many_pings" do
      HTTP2Spec.bounded do
        client, connection, peer = client_with_peer(options(keepalive_time: 1.second))
        peer.send(HTTP2::GoawayFrame.new(0_u32, EC::ENHANCE_YOUR_CALM, "too_many_pings".to_slice))
        HTTP2Spec.within(2.seconds, "connection close") { connection.wait_closed }
        HTTP2Spec.eventually(what: "keepalive back off") { client.options.keepalive_time == 2.seconds }
        client.connection.should_not be(connection)
      end
    end
  end

  describe "server keepalive" do
    it "pings an idle client and closes the connection when it does not answer" do
      release = Channel(Nil).new(1)
      opts = options(keepalive_time: 100.milliseconds, keepalive_timeout: 200.milliseconds)
      server = server_with(opts) { HTTP2Spec.receive(release, 10.seconds) rescue nil }
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          get(peer, 1)
          peer.expect(HTTP2::PingFrame).ack?.should be_false
          peer.expect_closed(2.seconds)
          release.send(nil)
        end
      end
    end
  end
end

describe "HTTP2 connection lifetime" do
  it "gracefully closes a connection idle for max_connection_idle" do
    server = server_with(options(max_connection_idle: 200.milliseconds)) { |ctx| ctx.response.print "ok" }
    HTTP2Spec.bounded do
      HTTP2Spec.with_raw_client(server) do |peer|
        peer.handshake
        get(peer, 1)
        peer.read_message(1)[1].should eq("ok")
        idle_since = Time.instant
        expect_graceful_goaway(peer, 1)
        (Time.instant - idle_since).should be >= 150.milliseconds
        peer.expect_closed
      end
    end
  end

  it "does not consider a connection with active streams idle" do
    release = Channel(Nil).new(1)
    server = server_with(options(max_connection_idle: 100.milliseconds)) do |ctx|
      HTTP2Spec.receive(release)
      ctx.response.print "ok"
    end
    HTTP2Spec.bounded do
      HTTP2Spec.with_raw_client(server) do |peer|
        peer.handshake
        get(peer, 1)
        peer.expect_silence(300.milliseconds)
        release.send(nil)
        peer.read_message(1)[1].should eq("ok")
        expect_graceful_goaway(peer, 1)
        peer.expect_closed
      end
    end
  end

  it "gracefully closes a connection after max_connection_age and lets streams finish" do
    release = Channel(Nil).new(1)
    opts = options(max_connection_age: 200.milliseconds, max_connection_age_jitter: 0.0)
    server = server_with(opts) do |ctx|
      HTTP2Spec.receive(release)
      ctx.response.print "ok"
    end
    HTTP2Spec.bounded do
      HTTP2Spec.with_raw_client(server) do |peer|
        started = Time.instant
        peer.handshake
        get(peer, 1)
        expect_graceful_goaway(peer, 1)
        (Time.instant - started).should be >= 150.milliseconds
        release.send(nil)
        peer.read_message(1)[1].should eq("ok")
        peer.expect_closed
      end
    end
  end

  it "forcibly closes the connection max_connection_age_grace after max_connection_age" do
    failed = Channel(Exception).new(1)
    opts = options(max_connection_age: 100.milliseconds, max_connection_age_jitter: 0.0,
      max_connection_age_grace: 300.milliseconds)
    server = server_with(opts) do |ctx|
      ctx.request.body.gets_to_end
    rescue e
      failed.send(e)
    end
    HTTP2Spec.bounded do
      HTTP2Spec.with_raw_client(server) do |peer|
        started = Time.instant
        peer.handshake
        get(peer, 1, end_stream: false)
        expect_graceful_goaway(peer, 1)
        goaway = peer.expect(HTTP2::GoawayFrame)
        String.new(goaway.debug_data).should eq("max_age")
        (Time.instant - started).should be >= 350.milliseconds
        peer.expect_closed
        HTTP2Spec.receive(failed).should be_a(HTTP2::ConnectionClosedError)
      end
    end
  end

  it "applies jitter to max_connection_age" do
    HTTP2Spec.bounded do
      opts = options(max_connection_age: 400.milliseconds, max_connection_age_jitter: 0.5)
      server = server_with(opts) { }
      HTTP2Spec.with_raw_client(server) do |peer|
        started = Time.instant
        peer.handshake
        expect_graceful_goaway(peer, 0)
        elapsed = Time.instant - started
        elapsed.should be >= 190.milliseconds
        elapsed.should be < 1.second
      end
    end
  end

  it "lets a client transparently move to new connections as old ones age out" do
    opts = options(max_connection_age: 150.milliseconds, max_connection_age_grace: 5.seconds)
    server = server_with(opts) { |ctx| ctx.response.print ctx.request.path }
    HTTP2Spec.bounded(30.seconds) do
      HTTP2Spec.with_server(server) do |client|
        connections = Set(HTTP2::Connection).new
        deadline = Time.instant + 800.milliseconds
        count = 0
        while Time.instant < deadline
          responses = Array.new(5) do |i|
            ch = Channel(String | Exception).new(1)
            spawn do
              ch.send(client.get("/#{count}-#{i}").body_text)
            rescue e
              ch.send(e)
            end
            ch
          end
          responses.each_with_index do |ch, i|
            result = HTTP2Spec.receive(ch)
            raise result if result.is_a?(Exception)
            result.should eq("/#{count}-#{i}")
          end
          connections << client.connection
          count += 1
        end
        connections.size.should be > 1
      end
    end
  end
end
