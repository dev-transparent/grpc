require "./support"
require "log/spec"

private alias EC = HTTP2::ErrorCode

private MAX_HEADER_LIST_SIZE = 6_u16

private def options(**args)
  HTTP2::ConnectionOptions.new(**args)
end

private def limit(count = 10)
  HTTP2::RateLimit.new(count, 10.seconds)
end

private def server_with(opts : HTTP2::ConnectionOptions, &block : HTTP2::Server::Context ->)
  HTTP2::Server.new(block, HTTP2::Server.default_settings, 16_777_216, opts)
end

private def ok_server(opts)
  server_with(opts) do |ctx|
    ctx.request.body.gets_to_end
    ctx.response.print "ok"
  end
end

private def with_peer(server, params = [] of {UInt16, UInt32}, &block : HTTP2Spec::RawPeer ->)
  HTTP2Spec.bounded do
    HTTP2Spec.with_raw_client(server) do |peer|
      peer.handshake(params)
      block.call(peer)
    end
  end
end

private def get(peer, id, end_stream = true)
  peer.send_headers(id, peer.request_fields("GET", "/"), end_stream: end_stream)
end

private def expect_alive(peer)
  data = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
  peer.send(HTTP2::PingFrame.new(data))
  ack = peer.expect(HTTP2::PingFrame)
  ack.ack?.should be_true
  ack.data.should eq(data)
end

private def expect_calm(peer, debug : Regex)
  goaway = peer.expect(HTTP2::GoawayFrame)
  goaway.error_code.should eq(EC::ENHANCE_YOUR_CALM)
  String.new(goaway.debug_data).should match(debug)
  peer.expect_closed
end

# Reads frames, ignoring all but GOAWAY.
private def next_goaway(peer) : HTTP2::GoawayFrame
  loop do
    frame = peer.next_frame || raise "Connection closed without GOAWAY"
    return frame if frame.is_a?(HTTP2::GoawayFrame)
  end
end

# Sends *count* frames of a kind that is subject to a flood limit of 10
# (plus *setup* frames counted against it).
private def flood(kind : Symbol, peer, count : Int32) : Nil
  case kind
  when :ping
    count.times { |i| peer.send(HTTP2::PingFrame.new(Bytes.new(8, i.to_u8))) }
  when :settings
    count.times { peer.send_settings }
  when :empty_data
    get(peer, 1, end_stream: false)
    count.times { peer.send_data(1, Bytes.empty) }
  when :empty_headers
    peer.send(HTTP2::HeadersFrame.new(1_u32, Bytes.empty, end_headers: false))
    (count - 1).times { peer.send(HTTP2::ContinuationFrame.new(1_u32, Bytes.empty, end_headers: false)) }
  when :unknown
    count.times { peer.send_raw(HTTP2Spec.raw_frame(0xfa_u8, 0_u8, 0_u32, Bytes[1, 2, 3])) }
  when :priority
    count.times { |i| peer.send(HTTP2::PriorityFrame.new((i * 2 + 1).to_u32, HTTP2::Priority.new(0_u32, 16_u8, false))) }
  when :window_update
    count.times { peer.send_window_update(0, 1) }
  end
end

private def flood_options(kind : Symbol)
  case kind
  when :ping          then options(max_ping_rate: limit)
  when :settings      then options(max_settings_rate: limit)
  when :priority      then options(max_priority_rate: limit)
  when :window_update then options(max_window_update_rate: limit)
  else                     options(max_empty_frame_rate: limit)
  end
end

describe "HTTP2 abuse protection" do
  describe "rapid reset (CVE-2023-44487)" do
    it "closes the connection with ENHANCE_YOUR_CALM when the peer resets too many streams" do
      with_peer(ok_server(options(max_peer_resets: limit))) do |peer|
        11.times do |i|
          get(peer, i * 2 + 1, end_stream: false)
          peer.send_rst(i * 2 + 1, EC::CANCEL)
        end
        expect_calm(peer, /Stream reset flood/)
      end
    end

    it "tolerates resets below the limit" do
      with_peer(ok_server(options(max_peer_resets: limit))) do |peer|
        10.times do |i|
          get(peer, i * 2 + 1, end_stream: false)
          peer.send_rst(i * 2 + 1, EC::CANCEL)
        end
        expect_alive(peer)
        get(peer, 21)
        peer.read_message(21)[1].should eq("ok")
      end
    end

    it "tolerates many cancellations when most streams complete normally" do
      # Legitimate traffic with frequent cancellations (deadlines, client
      # cancels) must not be mistaken for an attack: 3x the limit of
      # premature resets, but they are only a third of all streams.
      with_peer(ok_server(options(max_peer_resets: limit))) do |peer|
        id = 1
        30.times do
          get(peer, id, end_stream: false)
          peer.send_rst(id, EC::CANCEL)
          id += 2
          2.times do
            get(peer, id)
            peer.read_message(id)[1].should eq("ok")
            id += 2
          end
        end
        expect_alive(peer)
      end
    end

    it "does not count resets of streams that already completed" do
      # Responds without waiting for the (still open) request body.
      server = server_with(options(max_peer_resets: limit)) { |ctx| ctx.response.print "ok" }
      with_peer(server) do |peer|
        id = 1
        30.times do
          get(peer, id, end_stream: false)
          peer.read_message(id)
          # The server completed the response and asked us to stop sending.
          peer.expect_rst(id, EC::NO_ERROR)
          peer.send_rst(id, EC::CANCEL) # the response is complete; nothing to abort
          id += 2
        end
        expect_alive(peer)
      end
    end

    it "refuses new streams while too many handlers are still running" do
      release = Channel(Nil).new(10)
      server = server_with(options(max_running_handlers: 2)) do |ctx|
        HTTP2Spec.receive(release)
        ctx.response.print "ok" rescue nil
      end
      with_peer(server) do |peer|
        get(peer, 1)
        get(peer, 3)
        get(peer, 5)
        peer.expect_rst(5, EC::REFUSED_STREAM)
        # Resetting the streams does not free the handler slots.
        peer.send_rst(1, EC::CANCEL)
        peer.send_rst(3, EC::CANCEL)
        get(peer, 7)
        peer.expect_rst(7, EC::REFUSED_STREAM)
        3.times { release.send(nil) }
        # Once the handlers returned, streams are accepted again.
        id = 9
        loop do
          get(peer, id)
          frame = peer.expect(HTTP2::Frame)
          break if frame.is_a?(HTTP2::HeadersFrame)
          frame.should be_a(HTTP2::RstStreamFrame)
          id += 2
          sleep 10.milliseconds
        end
        peer.expect(HTTP2::DataFrame).stream_id.should eq(id)
      end
    end

    it "counts refused streams towards the reset limit" do
      release = Channel(Nil).new(20)
      server = server_with(options(max_running_handlers: 1, max_peer_resets: limit(3))) do |ctx|
        HTTP2Spec.receive(release)
      end
      with_peer(server) do |peer|
        get(peer, 1)
        3.times { |i| get(peer, i * 2 + 3) }
        get(peer, 9)
        goaway = next_goaway(peer)
        goaway.error_code.should eq(EC::ENHANCE_YOUR_CALM)
        String.new(goaway.debug_data).should match(/Stream reset flood/)
        release.send(nil)
      end
    end
  end

  describe "floods" do
    {% for kind in %i(ping settings empty_data empty_headers unknown priority window_update) %}
      it "closes the connection on a {{kind.id}} flood" do
        with_peer(ok_server(flood_options({{kind}}))) do |peer|
          # The handshake already sent one SETTINGS and one SETTINGS ACK.
          count = {{kind}} == :settings ? 9 : 11
          flood({{kind}}, peer, count)
          goaway = next_goaway(peer)
          goaway.error_code.should eq(EC::ENHANCE_YOUR_CALM)
          String.new(goaway.debug_data).should match(/flood/)
          peer.expect_closed
        end
      end

      it "accepts {{kind.id}} frames below the limit" do
        with_peer(ok_server(flood_options({{kind}}))) do |peer|
          count = {{kind}} == :settings ? 8 : 10
          flood({{kind}}, peer, count)
          if {{kind}} == :empty_headers
            peer.send(HTTP2::ContinuationFrame.new(1_u32, peer.encode(peer.request_fields), end_headers: true))
          end
          if {{kind}} == :empty_headers || {{kind}} == :empty_data
            peer.send_data(1, "", end_stream: true)
            peer.read_message(1)[1].should eq("ok")
          end
          peer.collect(100.milliseconds).none?(HTTP2::GoawayFrame).should be_true
          get(peer, 101)
          peer.read_message(101)[1].should eq("ok")
        end
      end
    {% end %}
  end

  describe "legitimate control traffic" do
    it "does not count PINGs and WINDOW_UPDATEs answering our DATA (grpc-go BDP estimation)" do
      opts = options(max_ping_rate: limit(5), max_window_update_rate: limit(5), min_ping_interval: 5.minutes)
      server = server_with(opts) { |ctx| ctx.response.print "ok" }
      with_peer(server) do |peer|
        40.times do |i|
          id = i * 2 + 1
          get(peer, id)
          peer.read_message(id)[1].should eq("ok")
          peer.send(HTTP2::PingFrame.new(Bytes.new(8, i.to_u8)))
          peer.send_window_update(0, 2)
          peer.expect(HTTP2::PingFrame).ack?.should be_true
        end
        peer.collect(50.milliseconds).none?(HTTP2::GoawayFrame).should be_true
        # Without DATA in between, the limit still applies.
        6.times { |i| peer.send(HTTP2::PingFrame.new(Bytes.new(8, i.to_u8))) }
        goaway = next_goaway(peer)
        goaway.error_code.should eq(EC::ENHANCE_YOUR_CALM)
      end
    end
  end

  describe "outgoing control frame queue" do
    it "closes the connection when a peer provokes control frames without reading them" do
      HTTP2Spec.bounded do
        client_io, server_io = UNIXSocket.pair
        connection = HTTP2::Connection.new(server_io, HTTP2::Connection::Role::Server,
          options: options(max_ping_rate: nil, max_queued_control_frames: 100))
        connection.start
        spawn do
          client_io.write(HTTP2::Connection::CLIENT_PREFACE)
          HTTP2::SettingsFrame.new.write(client_io)
          ping = HTTP2::PingFrame.new(Bytes.new(8)).to_slice
          20_000.times { client_io.write(ping) }
          client_io.flush
        rescue IO::Error
        end
        HTTP2Spec.within(5.seconds, "server connection to terminate") { connection.wait_closed }
        error = connection.close_error.as(HTTP2::ConnectionClosedError)
        error.code.should eq(EC::ENHANCE_YOUR_CALM)
        error.message.to_s.should contain("control frames")
        HTTP2Spec.close_socket(client_io)
      end
    end

    it "does not limit a peer that reads its responses" do
      with_peer(ok_server(options(max_ping_rate: nil, max_queued_control_frames: 100))) do |peer|
        20.times do
          50.times { |i| peer.send(HTTP2::PingFrame.new(Bytes.new(8, i.to_u8!))) }
          50.times { peer.expect(HTTP2::PingFrame).ack?.should be_true }
        end
        expect_alive(peer)
      end
    end
  end

  describe "header list size on send" do
    it "raises HeaderListSizeError before sending a request whose headers are too large" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        connection = client.connection
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake([{MAX_HEADER_LIST_SIZE, 200_u32}])
        error = expect_raises(HTTP2::HeaderListSizeError) do
          connection.open_stream(peer.request_fields("GET", "/", [{"x-big", "a" * 200}]))
        end
        error.limit.should eq(200)
        error.size.should be > 200
        peer.expect_silence(50.milliseconds)
        connection.active_streams.should eq(0)
        # The connection (and HPACK state) is still usable.
        stream = connection.open_stream(peer.request_fields, end_stream: true)
        stream.id.should eq(1)
        peer.expect_headers(1)[0].should eq(peer.request_fields)
        peer.send_headers(1, [{":status", "200"}], end_stream: true)
        stream.wait_closed(2.seconds).should be_true
        client.close
      end
    end

    it "resets the stream with INTERNAL_ERROR when response headers are too large" do
      raised = Channel(Exception).new(1)
      server = HTTP2::Server.new do |ctx|
        ctx.response.headers["x-big"] = "a" * 300
        begin
          ctx.response.flush
        rescue e
          raised.send(e)
        end
      end
      Log.capture("http2.server") do
        with_peer(server, [{MAX_HEADER_LIST_SIZE, 200_u32}]) do |peer|
          get(peer, 1)
          peer.expect_rst(1, EC::INTERNAL_ERROR)
          HTTP2Spec.receive(raised).should be_a(HTTP2::HeaderListSizeError)
          get(peer, 3)
          peer.expect_alive_rst_or_response(3)
        end
      end
    end

    it "sends header lists at the limit" do
      server = HTTP2::Server.new { |ctx| ctx.response.print "ok" }
      with_peer(server, [{MAX_HEADER_LIST_SIZE, 64_u32}]) do |peer|
        get(peer, 1)
        # ":status" (7) + "200" (3) + 32 = 42 octets.
        peer.read_message(1)[0].should eq([{":status", "200"}])
      end
    end
  end

  describe "stream identifier exhaustion" do
    it "makes the client move to a new connection" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        connection = client.connection
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        connection.next_stream_id = HTTP2::MAX_STREAM_ID
        stream = connection.open_stream(peer.request_fields, end_stream: true)
        stream.id.should eq(HTTP2::MAX_STREAM_ID)
        connection.available?.should be_false
        expect_raises(HTTP2::RefusedStreamError, /exhausted/) { connection.open_stream(peer.request_fields) }

        response = Channel(Int32).new(1)
        spawn { response.send(client.get("/").status) }
        peer2 = HTTP2Spec.receive(peers)
        peer2.server_handshake
        peer2.expect_headers(1)
        peer2.send_headers(1, [{":status", "200"}], end_stream: true)
        HTTP2Spec.receive(response).should eq(200)

        # The old connection finishes its last stream, then says goodbye.
        peer.expect_headers(HTTP2::MAX_STREAM_ID)
        peer.send_headers(HTTP2::MAX_STREAM_ID, [{":status", "200"}], end_stream: true)
        stream.headers.should eq([{":status", "200"}])
        peer.expect(HTTP2::GoawayFrame).error_code.should eq(EC::NO_ERROR)
        peer.expect_closed
        client.close
      end
    end

    it "makes the server drain a connection whose peer used the last stream identifier" do
      server = HTTP2::Server.new { |ctx| ctx.response.print "last" }
      with_peer(server) do |peer|
        get(peer, HTTP2::MAX_STREAM_ID)
        frames = [] of HTTP2::Frame
        goaway = peer.expect(HTTP2::GoawayFrame)
        goaway.last_stream_id.should eq(HTTP2::MAX_STREAM_ID)
        ping = nil
        until ping
          frame = peer.next_frame || raise "closed"
          if frame.is_a?(HTTP2::PingFrame)
            ping = frame
          else
            frames << frame
          end
        end
        peer.send(HTTP2::PingFrame.new(ping.data, ack: true))
        loop do
          frame = peer.next_frame || break
          frames << frame
        end
        frames.any? { |f| f.is_a?(HTTP2::DataFrame) && String.new(f.data) == "last" }.should be_true
        frames.select(HTTP2::GoawayFrame).map(&.last_stream_id).should eq([HTTP2::MAX_STREAM_ID])
      end
    end
  end

  describe "SETTINGS timeout" do
    it "closes the connection with SETTINGS_TIMEOUT when SETTINGS are not acknowledged" do
      HTTP2Spec.bounded do
        server = ok_server(options(settings_timeout: 200.milliseconds))
        HTTP2Spec.with_raw_client(server) do |peer|
          started = Time.instant
          peer.send_preface
          peer.send_settings
          goaway = next_goaway(peer)
          goaway.error_code.should eq(EC::SETTINGS_TIMEOUT)
          (Time.instant - started).should be >= 150.milliseconds
          peer.expect_closed
        end
      end
    end

    it "keeps connections that acknowledge SETTINGS" do
      with_peer(ok_server(options(settings_timeout: 100.milliseconds))) do |peer|
        peer.expect_silence(300.milliseconds)
        get(peer, 1)
        peer.read_message(1)[1].should eq("ok")
      end
    end

    it "makes the client give up on a server that never acknowledges" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client(options: options(settings_timeout: 200.milliseconds))
        connection = client.connection
        peer = HTTP2Spec.receive(peers)
        peer.send_settings
        HTTP2Spec.within(2.seconds, "connection close") { connection.wait_closed }
        connection.close_error.as(HTTP2::ConnectionClosedError).code.should eq(EC::SETTINGS_TIMEOUT)
      end
    end
  end
end

class HTTP2Spec::RawPeer
  # The connection survived: stream *id* gets a response or a reset, and a
  # PING is answered.
  def expect_alive_rst_or_response(id : Int) : Nil
    loop do
      frame = next_frame || raise "Connection closed"
      next unless frame.stream_id == id.to_u32
      break if frame.is_a?(HTTP2::RstStreamFrame) || (frame.is_a?(HTTP2::HeadersFrame) && frame.end_stream?) ||
               (frame.is_a?(HTTP2::DataFrame) && frame.end_stream?)
    end
  end
end
