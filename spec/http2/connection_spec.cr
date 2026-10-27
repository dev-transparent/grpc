require "./support"

private alias EC = HTTP2::ErrorCode

private HEADER_TABLE_SIZE      = 1_u16
private ENABLE_PUSH            = 2_u16
private MAX_CONCURRENT_STREAMS = 3_u16
private INITIAL_WINDOW_SIZE    = 4_u16
private MAX_FRAME_SIZE         = 5_u16

private def server_settings(max_concurrent_streams : UInt32? = 100_u32, initial_window_size : UInt32 = 1_048_576_u32,
                            max_frame_size : UInt32 = 16_384_u32, max_header_list_size : UInt32? = 1_048_576_u32)
  HTTP2::Settings.new(max_concurrent_streams: max_concurrent_streams, initial_window_size: initial_window_size,
    max_frame_size: max_frame_size, max_header_list_size: max_header_list_size)
end

# Responds with "hello <path>".
private def hello_server(settings = server_settings, window = 16_777_216)
  HTTP2::Server.new(settings, window) do |ctx|
    ctx.response.headers["content-type"] = "text/plain"
    ctx.response.print "hello #{ctx.request.path}"
  end
end

# Reads the whole request body and echoes it back, with request trailers
# mirrored as response trailers.
private def echo_server(settings = server_settings, window = 16_777_216)
  HTTP2::Server.new(settings, window) do |ctx|
    body = ctx.request.body.gets_to_end
    ctx.response.print body
    ctx.request.trailers.try &.each do |name, values|
      ctx.response.trailers[name] = values
    end
  end
end

# Responds with *size* bytes of "a".
private def sized_server(size : Int32, settings = server_settings, window = 16_777_216)
  HTTP2::Server.new(settings, window) do |ctx|
    ctx.response.write(("a" * size).to_slice)
  end
end

private def with_peer(server : HTTP2::Server, params = [] of {UInt16, UInt32}, &block : HTTP2Spec::RawPeer ->)
  HTTP2Spec.bounded do
    HTTP2Spec.with_raw_client(server) do |peer|
      peer.handshake(params)
      block.call(peer)
    end
  end
end

private def get(peer, id, path = "/", end_stream = true)
  peer.send_headers(id, peer.request_fields("GET", path), end_stream: end_stream)
end

private def post(peer, id, extra = [] of {String, String})
  peer.send_headers(id, peer.request_fields("POST", "/", extra), end_stream: false)
end

private def expect_alive(peer)
  data = Bytes[9, 8, 7, 6, 5, 4, 3, 2]
  peer.send(HTTP2::PingFrame.new(data))
  ack = peer.expect(HTTP2::PingFrame)
  ack.ack?.should be_true
  ack.data.should eq(data)
end

private def read_data(peer, stream_id, total : Int32) : Array(HTTP2::DataFrame)
  frames = [] of HTTP2::DataFrame
  received = 0
  while received < total
    frame = peer.expect(HTTP2::DataFrame)
    frame.stream_id.should eq(stream_id.to_u32)
    received += frame.data.size
    frames << frame
  end
  received.should eq(total)
  frames
end

# Expects END_STREAM, either on the last DATA frame read or on a following
# empty DATA frame.
private def expect_end_stream(peer, frames : Array(HTTP2::DataFrame))
  return if frames.last?.try(&.end_stream?)
  frame = peer.expect(HTTP2::DataFrame)
  frame.data.empty?.should be_true
  frame.end_stream?.should be_true
end

# Expects the two-phase graceful shutdown: GOAWAY(2^31-1) with a PING, then
# (after the PING is acknowledged) GOAWAY with *last_stream_id*. Yields
# between the two phases (streams opened then are still processed).
private def expect_two_phase_goaway(peer, last_stream_id : Int, &)
  first = peer.expect(HTTP2::GoawayFrame)
  first.error_code.should eq(EC::NO_ERROR)
  first.last_stream_id.should eq(HTTP2::MAX_STREAM_ID)
  ping = peer.expect(HTTP2::PingFrame)
  ping.ack?.should be_false
  yield
  peer.send(HTTP2::PingFrame.new(ping.data, ack: true))
  final = peer.expect(HTTP2::GoawayFrame)
  final.error_code.should eq(EC::NO_ERROR)
  final.last_stream_id.should eq(last_stream_id.to_u32)
  final
end

private def expect_two_phase_goaway(peer, last_stream_id : Int)
  expect_two_phase_goaway(peer, last_stream_id) { }
end

describe HTTP2::Connection do
  describe "connection preface" do
    it "sends SETTINGS and a connection WINDOW_UPDATE, then ACKs the client SETTINGS" do
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(hello_server) do |peer|
          peer.send_preface
          peer.send_settings([{INITIAL_WINDOW_SIZE, 100_u32}])
          settings = peer.expect(HTTP2::SettingsFrame, skip_noise: false)
          settings.ack?.should be_false
          settings.parameters.should eq([{MAX_CONCURRENT_STREAMS, 100_u32}, {INITIAL_WINDOW_SIZE, 1_048_576_u32}, {6_u16, 1_048_576_u32}])
          update = peer.expect(HTTP2::WindowUpdateFrame, skip_noise: false)
          update.stream_id.should eq(0)
          update.increment.should eq(16_777_216 - 65_535)
          ack = peer.expect(HTTP2::SettingsFrame, skip_noise: false)
          ack.ack?.should be_true
          peer.send(HTTP2::SettingsFrame.ack)
          expect_alive(peer)
        end
      end
    end

    it "does not send a WINDOW_UPDATE when the connection window is the default" do
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(hello_server(window: 65_535)) do |peer|
          peer.send_preface
          peer.send_settings
          peer.expect(HTTP2::SettingsFrame, skip_noise: false).ack?.should be_false
          peer.expect(HTTP2::SettingsFrame, skip_noise: false).ack?.should be_true
        end
      end
    end

    it "rejects an invalid preface with GOAWAY PROTOCOL_ERROR" do
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(hello_server) do |peer|
          peer.send_raw("PRI * HTTP/2.0\r\n\r\nXX\r\n\r\n".to_slice)
          peer.expect(HTTP2::SettingsFrame)
          peer.expect_goaway(EC::PROTOCOL_ERROR)
        end
      end
    end

    it "rejects an HTTP/1.1 request" do
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(hello_server) do |peer|
          peer.send_raw("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".to_slice)
          peer.expect(HTTP2::SettingsFrame)
          peer.expect_goaway(EC::PROTOCOL_ERROR)
        end
      end
    end

    it "requires the first frame to be SETTINGS" do
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(hello_server) do |peer|
          peer.send_preface
          peer.send(HTTP2::PingFrame.new)
          peer.expect(HTTP2::SettingsFrame)
          peer.expect_goaway(EC::PROTOCOL_ERROR)
        end
      end
    end

    it "requires the first SETTINGS frame not to be an ACK" do
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(hello_server) do |peer|
          peer.send_preface
          peer.send(HTTP2::SettingsFrame.ack)
          peer.expect(HTTP2::SettingsFrame)
          peer.expect_goaway(EC::PROTOCOL_ERROR)
        end
      end
    end

    it "closes cleanly when the client disconnects" do
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(hello_server) do |peer|
          peer.handshake
          peer.close
        end
      end
    end
  end

  describe "connection level frames" do
    it "answers PING with a PING ACK carrying the same data" do
      with_peer(hello_server) do |peer|
        expect_alive(peer)
        expect_alive(peer)
      end
    end

    it "ignores unsolicited PING ACKs" do
      with_peer(hello_server) do |peer|
        peer.send(HTTP2::PingFrame.new(Bytes.new(8), ack: true))
        peer.expect_silence(100.milliseconds)
        expect_alive(peer)
      end
    end

    it "ACKs every SETTINGS frame" do
      with_peer(hello_server) do |peer|
        peer.send_settings([{HEADER_TABLE_SIZE, 0_u32}])
        peer.expect(HTTP2::SettingsFrame, skip_noise: false).ack?.should be_true
        peer.send_settings
        peer.expect(HTTP2::SettingsFrame, skip_noise: false).ack?.should be_true
      end
    end

    it "ignores unknown settings and unknown frame types" do
      with_peer(hello_server) do |peer|
        peer.send_settings([{0x99_u16, 1_u32}])
        peer.send_raw(HTTP2Spec.raw_frame(0xee_u8, 0xff_u8, 0_u32, Bytes[1, 2, 3]))
        peer.send_raw(HTTP2Spec.raw_frame(0xee_u8, 0_u8, 1_u32, Bytes.empty))
        expect_alive(peer)
        get(peer, 1)
        peer.read_message(1)[1].should eq("hello /")
      end
    end

    it "uses the dynamic table size requested by SETTINGS_HEADER_TABLE_SIZE" do
      with_peer(hello_server, [{HEADER_TABLE_SIZE, 0_u32}]) do |peer|
        peer.decoder.max_table_size_limit = 0
        get(peer, 1)
        headers, frame = peer.expect_headers(1)
        frame.fragment[0].should eq(0x20) # table size update to 0
        headers.should eq([{":status", "200"}, {"content-type", "text/plain"}])
        peer.decoder.table.length.should eq(0)
      end
    end

    it "rejects invalid SETTINGS values" do
      {
        {ENABLE_PUSH, 2_u32, EC::PROTOCOL_ERROR},
        {INITIAL_WINDOW_SIZE, 0x80000000_u32, EC::FLOW_CONTROL_ERROR},
        {MAX_FRAME_SIZE, 16_383_u32, EC::PROTOCOL_ERROR},
        {MAX_FRAME_SIZE, 16_777_216_u32, EC::PROTOCOL_ERROR},
      }.each do |(id, value, code)|
        with_peer(hello_server) do |peer|
          peer.send_settings([{id, value}])
          peer.expect_goaway(code)
        end
      end
    end

    it "rejects a SETTINGS frame with an invalid length" do
      with_peer(hello_server) do |peer|
        peer.send_raw(HTTP2Spec.raw_frame(HTTP2::FrameType::SETTINGS, 0_u8, 0_u32, Bytes.new(3)))
        peer.expect_goaway(EC::FRAME_SIZE_ERROR)
      end
    end

    it "rejects a SETTINGS ACK with a payload" do
      with_peer(hello_server) do |peer|
        peer.send_raw(HTTP2Spec.raw_frame(HTTP2::FrameType::SETTINGS, 1_u8, 0_u32, Bytes.new(6)))
        peer.expect_goaway(EC::FRAME_SIZE_ERROR)
      end
    end

    it "rejects frames larger than SETTINGS_MAX_FRAME_SIZE" do
      with_peer(echo_server) do |peer|
        get(peer, 1, end_stream: false)
        spawn { peer.try_send(HTTP2::DataFrame.new(1_u32, Bytes.new(16_385))) }
        peer.expect_goaway(EC::FRAME_SIZE_ERROR)
      end
    end

    it "accepts frames up to an increased SETTINGS_MAX_FRAME_SIZE" do
      with_peer(echo_server(server_settings(max_frame_size: 65_536_u32))) do |peer|
        post(peer, 1)
        peer.send_data(1, Bytes.new(65_536, 'x'.ord.to_u8), end_stream: true)
        peer.read_message(1, replenish: true)[1].should eq("x" * 65_536)
      end
    end

    it "sends DATA frames no larger than the peer's SETTINGS_MAX_FRAME_SIZE" do
      with_peer(sized_server(100_000), [{MAX_FRAME_SIZE, 20_000_u32}, {INITIAL_WINDOW_SIZE, 1_000_000_u32}]) do |peer|
        peer.send_window_update(0, 1_000_000)
        get(peer, 1)
        peer.expect_headers(1)
        frames = read_data(peer, 1, 100_000)
        frames.map(&.data.size).max.should eq(20_000)
        expect_end_stream(peer, frames)
      end
    end

    it "treats PUSH_PROMISE from a client as a connection error" do
      with_peer(hello_server) do |peer|
        get(peer, 1, end_stream: false)
        peer.send(HTTP2::PushPromiseFrame.new(1_u32, 2_u32, peer.encode(peer.request_fields)))
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "closes the connection after a GOAWAY when no streams are active" do
      with_peer(hello_server) do |peer|
        peer.send(HTTP2::GoawayFrame.new(0_u32, EC::NO_ERROR))
        peer.expect_closed
      end
    end

    it "finishes active streams after receiving GOAWAY" do
      release = Channel(Nil).new(1)
      server = HTTP2::Server.new(server_settings) do |ctx|
        HTTP2Spec.receive(release)
        ctx.response.print "done"
      end
      with_peer(server) do |peer|
        get(peer, 1)
        peer.send(HTTP2::GoawayFrame.new(0_u32, EC::NO_ERROR))
        peer.expect_silence(100.milliseconds)
        release.send(nil)
        peer.read_message(1)[1].should eq("done")
        peer.expect_closed
      end
    end
  end

  describe "requests" do
    it "serves a GET request" do
      with_peer(hello_server) do |peer|
        get(peer, 1, "/path?q=1")
        headers, body, trailers = peer.read_message(1)
        headers.should eq([{":status", "200"}, {"content-type", "text/plain"}])
        body.should eq("hello /path?q=1")
        trailers.should be_nil
      end
    end

    it "serves sequential and interleaved streams" do
      with_peer(echo_server) do |peer|
        post(peer, 1)
        post(peer, 3)
        peer.send_data(3, "three")
        peer.send_data(1, "one")
        peer.send_data(3, "", end_stream: true)
        peer.read_message(3)[1].should eq("three")
        peer.send_data(1, "!", end_stream: true)
        peer.read_message(1)[1].should eq("one!")
        post(peer, 5)
        peer.send_data(5, "five", end_stream: true)
        peer.read_message(5)[1].should eq("five")
      end
    end

    it "sends an empty response with END_STREAM on the HEADERS frame" do
      server = HTTP2::Server.new(server_settings) { |ctx| ctx.response.status = 204 }
      with_peer(server) do |peer|
        get(peer, 1)
        headers, frame = peer.expect_headers(1)
        headers.should eq([{":status", "204"}])
        frame.end_stream?.should be_true
      end
    end

    it "accepts header blocks split across CONTINUATION frames" do
      with_peer(hello_server) do |peer|
        block = peer.encode(peer.request_fields("GET", "/continued", [{"x-pad", "p" * 100}]))
        peer.send(HTTP2::HeadersFrame.new(1_u32, block[0, 3], end_stream: true, end_headers: false))
        peer.send(HTTP2::ContinuationFrame.new(1_u32, block[3, 10], end_headers: false))
        peer.send(HTTP2::ContinuationFrame.new(1_u32, Bytes.empty, end_headers: false))
        peer.send(HTTP2::ContinuationFrame.new(1_u32, block[13..], end_headers: true))
        peer.read_message(1)[1].should eq("hello /continued")
      end
    end

    it "accepts padded HEADERS and DATA and HEADERS with priority" do
      with_peer(echo_server) do |peer|
        peer.send_headers(1, peer.request_fields("POST"), priority: HTTP2::Priority.new(0_u32, 16_u8, false), padding: 20)
        peer.send_data(1, "padded", end_stream: true, padding: 100)
        peer.read_message(1)[1].should eq("padded")
      end
    end

    it "sends response headers larger than the frame size in CONTINUATION frames" do
      big = "v" * 40_000
      server = HTTP2::Server.new(server_settings) { |ctx| ctx.response.headers["x-big"] = big }
      with_peer(server) do |peer|
        get(peer, 1)
        frame = peer.expect(HTTP2::HeadersFrame)
        frame.end_headers?.should be_false
        block = IO::Memory.new
        block.write(frame.fragment)
        loop do
          cont = peer.expect(HTTP2::ContinuationFrame, skip_noise: false)
          cont.fragment.size.should be <= 16_384
          block.write(cont.fragment)
          break if cont.end_headers?
        end
        peer.decoder.decode(block.to_slice).should eq([{":status", "200"}, {"x-big", big}])
      end
    end

    it "receives request trailers and sends response trailers" do
      server = HTTP2::Server.new(server_settings) do |ctx|
        body = ctx.request.body.gets_to_end
        ctx.response.print "#{body}|#{ctx.request.trailers.try &.["x-checksum"]}"
        ctx.response.trailers["x-status"] = "ok"
      end
      with_peer(server) do |peer|
        post(peer, 1)
        peer.send_data(1, "abc")
        peer.send_headers(1, [{"x-checksum", "123"}], end_stream: true)
        headers, body, trailers = peer.read_message(1)
        headers.should eq([{":status", "200"}])
        body.should eq("abc|123")
        trailers.should eq([{"x-status", "ok"}])
      end
    end

    it "accepts trailers directly after the request headers" do
      with_peer(echo_server) do |peer|
        post(peer, 1)
        peer.send_headers(1, [{"x-t", "1"}], end_stream: true)
        _, body, trailers = peer.read_message(1)
        body.should eq("")
        trailers.should eq([{"x-t", "1"}])
      end
    end

    it "responds with 500 when the handler raises before sending headers" do
      server = HTTP2::Server.new(server_settings) do |ctx|
        ctx.response.headers["x-lost"] = "1"
        raise "boom"
      end
      HTTP2::Server::Log.level = ::Log::Severity::None
      begin
        with_peer(server) do |peer|
          get(peer, 1)
          headers, body, _ = peer.read_message(1)
          headers.should eq([{":status", "500"}])
          body.should eq("")
        end
      ensure
        HTTP2::Server::Log.level = ::Log::Severity::Info
      end
    end

    it "resets the stream with INTERNAL_ERROR when the handler raises after sending headers" do
      server = HTTP2::Server.new(server_settings) do |ctx|
        ctx.response.print "partial"
        ctx.response.flush
        raise "boom"
      end
      HTTP2::Server::Log.level = ::Log::Severity::None
      begin
        with_peer(server) do |peer|
          get(peer, 1)
          peer.expect_headers(1)
          String.new(peer.expect(HTTP2::DataFrame).data).should eq("partial")
          peer.expect_rst(1, EC::INTERNAL_ERROR)
        end
      ensure
        HTTP2::Server::Log.level = ::Log::Severity::Info
      end
    end

    it "resets with NO_ERROR when responding before the request body is complete" do
      with_peer(hello_server) do |peer|
        get(peer, 1, end_stream: false)
        peer.read_message(1)[1].should eq("hello /")
        peer.expect_rst(1, EC::NO_ERROR)
        expect_alive(peer)
      end
    end
  end

  describe "stream errors" do
    it "resets malformed requests with PROTOCOL_ERROR and keeps the connection" do
      malformed = [
        [{":method", "GET"}, {":scheme", "http"}],
        [{":method", "GET"}, {":scheme", "http"}, {":path", "/"}, {"Upper", "x"}],
        [{":method", "GET"}, {":scheme", "http"}, {":path", "/"}, {"connection", "close"}],
        [{":method", "GET"}, {":scheme", "http"}, {":path", "/"}, {":status", "200"}],
        [{"x", "y"}, {":method", "GET"}, {":scheme", "http"}, {":path", "/"}],
      ]
      with_peer(hello_server) do |peer|
        malformed.each_with_index do |fields, i|
          id = i * 2 + 1
          peer.send_headers(id, fields, end_stream: true)
          peer.expect_rst(id, EC::PROTOCOL_ERROR)
        end
        get(peer, 11)
        peer.read_message(11)[1].should eq("hello /")
      end
    end

    it "resets a stream that depends on itself" do
      with_peer(hello_server) do |peer|
        peer.send_headers(1, peer.request_fields, end_stream: true, priority: HTTP2::Priority.new(1_u32, 16_u8, false))
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
        peer.send(HTTP2::PriorityFrame.new(3_u32, HTTP2::Priority.new(3_u32, 16_u8, false)))
        peer.expect_rst(3, EC::PROTOCOL_ERROR)
        expect_alive(peer)
      end
    end

    it "accepts PRIORITY frames for idle and closed streams" do
      with_peer(hello_server) do |peer|
        peer.send(HTTP2::PriorityFrame.new(9_u32, HTTP2::Priority.new(0_u32, 16_u8, false)))
        get(peer, 1)
        peer.read_message(1)
        peer.send(HTTP2::PriorityFrame.new(1_u32, HTTP2::Priority.new(0_u32, 16_u8, false)))
        expect_alive(peer)
      end
    end

    it "resets a stream when a PRIORITY frame has the wrong length" do
      with_peer(hello_server) do |peer|
        peer.send_raw(HTTP2Spec.raw_frame(HTTP2::FrameType::PRIORITY, 0_u8, 1_u32, Bytes.new(4)))
        peer.expect_rst(1, EC::FRAME_SIZE_ERROR)
        expect_alive(peer)
      end
    end

    it "resets with STREAM_CLOSED when DATA arrives after END_STREAM" do
      with_peer(echo_server) do |peer|
        post(peer, 1)
        peer.send_data(1, "x", end_stream: true)
        peer.read_message(1)
        peer.send_data(1, "more")
        peer.expect_rst(1, EC::STREAM_CLOSED)
        expect_alive(peer)
      end
    end

    it "resets with STREAM_CLOSED when DATA arrives on a half-closed (remote) stream" do
      release = Channel(Nil).new(1)
      server = HTTP2::Server.new(server_settings) do |ctx|
        HTTP2Spec.receive(release)
        ctx.response.print "late"
      end
      with_peer(server) do |peer|
        get(peer, 1)
        peer.send_data(1, "more")
        peer.expect_rst(1, EC::STREAM_CLOSED)
        release.send(nil)
        expect_alive(peer)
      end
    end

    it "treats HEADERS on a closed stream as a connection error" do
      with_peer(hello_server) do |peer|
        get(peer, 1)
        peer.read_message(1)
        get(peer, 1)
        peer.expect_goaway(EC::STREAM_CLOSED)
      end
    end

    it "ignores frames on streams it has reset" do
      with_peer(hello_server) do |peer|
        peer.send_headers(1, [{":method", "GET"}], end_stream: false)
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
        peer.send_data(1, "ignored")
        peer.send_headers(1, [{"x-trailer", "1"}], end_stream: true)
        peer.send(HTTP2::WindowUpdateFrame.new(1_u32, 10_u32))
        peer.send_rst(1, EC::CANCEL)
        peer.expect_silence(100.milliseconds)
        expect_alive(peer)
      end
    end

    it "treats frames on idle streams as connection errors" do
      [
        HTTP2::DataFrame.new(1_u32, "x".to_slice),
        HTTP2::RstStreamFrame.new(1_u32, EC::CANCEL),
        HTTP2::WindowUpdateFrame.new(1_u32, 1_u32),
      ].each do |frame|
        with_peer(hello_server) do |peer|
          peer.send(frame)
          peer.expect_goaway(EC::PROTOCOL_ERROR)
        end
      end
    end

    it "rejects HEADERS on a server initiated (even) stream identifier" do
      with_peer(hello_server) do |peer|
        get(peer, 2)
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "rejects HEADERS with a stream identifier lower than a previous one" do
      with_peer(hello_server) do |peer|
        get(peer, 5)
        peer.read_message(5)
        get(peer, 3)
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "rejects DATA on stream 0" do
      with_peer(hello_server) do |peer|
        peer.send_raw(HTTP2Spec.raw_frame(HTTP2::FrameType::DATA, 0_u8, 0_u32, Bytes[1]))
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "rejects invalid padding" do
      with_peer(hello_server) do |peer|
        get(peer, 1, end_stream: false)
        peer.send_raw(HTTP2Spec.raw_frame(HTTP2::FrameType::DATA, HTTP2::Flags::PADDED, 1_u32, Bytes[5, 1, 2]))
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "rejects undecodable header blocks with COMPRESSION_ERROR" do
      with_peer(hello_server) do |peer|
        peer.send(HTTP2::HeadersFrame.new(1_u32, Bytes[0x80], end_stream: true))
        peer.expect_goaway(EC::COMPRESSION_ERROR)
      end
    end

    it "rejects an invalid Huffman string with COMPRESSION_ERROR" do
      with_peer(hello_server) do |peer|
        peer.send(HTTP2::HeadersFrame.new(1_u32, Bytes[0x82, 0x84, 0x86, 0x41, 0x81, 0x00], end_stream: true))
        peer.expect_goaway(EC::COMPRESSION_ERROR)
      end
    end

    it "resets streams whose header list exceeds SETTINGS_MAX_HEADER_LIST_SIZE, keeping HPACK in sync" do
      with_peer(hello_server(server_settings(max_header_list_size: 500_u32))) do |peer|
        peer.send_headers(1, peer.request_fields("GET", "/", [{"x-shared", "1"}, {"x-big", "b" * 600}]), end_stream: true)
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
        # x-shared is now referenced from the dynamic table.
        block = peer.encode(peer.request_fields("GET", "/after", [{"x-shared", "1"}]))
        block.size.should be < 20
        peer.send(HTTP2::HeadersFrame.new(3_u32, block, end_stream: true))
        peer.read_message(3)[1].should eq("hello /after")
      end
    end
  end

  describe "CONTINUATION" do
    it "requires CONTINUATION after HEADERS without END_HEADERS" do
      with_peer(hello_server) do |peer|
        block = peer.encode(peer.request_fields)
        peer.send(HTTP2::HeadersFrame.new(1_u32, block[0, 2], end_stream: true, end_headers: false))
        peer.send(HTTP2::PingFrame.new)
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "requires CONTINUATION on the same stream" do
      with_peer(hello_server) do |peer|
        block = peer.encode(peer.request_fields)
        peer.send(HTTP2::HeadersFrame.new(1_u32, block[0, 2], end_stream: true, end_headers: false))
        peer.send(HTTP2::ContinuationFrame.new(3_u32, block[2..], end_headers: true))
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "rejects DATA interleaved in a header block" do
      with_peer(hello_server) do |peer|
        block = peer.encode(peer.request_fields)
        peer.send(HTTP2::HeadersFrame.new(1_u32, block[0, 2], end_stream: false, end_headers: false))
        peer.send_data(1, "x")
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "rejects a CONTINUATION frame without a preceding HEADERS frame" do
      with_peer(hello_server) do |peer|
        peer.send(HTTP2::ContinuationFrame.new(1_u32, peer.encode(peer.request_fields), end_headers: true))
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "rejects a CONTINUATION frame after a complete header block" do
      with_peer(hello_server) do |peer|
        get(peer, 1, end_stream: false)
        peer.send(HTTP2::ContinuationFrame.new(1_u32, Bytes[0x82], end_headers: true))
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "rejects a stream error frame in the middle of a header block as a connection error" do
      with_peer(hello_server) do |peer|
        block = peer.encode(peer.request_fields)
        peer.send(HTTP2::HeadersFrame.new(1_u32, block[0, 2], end_stream: true, end_headers: false))
        peer.send_raw(HTTP2Spec.raw_frame(HTTP2::FrameType::PRIORITY, 0_u8, 1_u32, Bytes.new(4)))
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
    end

    it "limits the size of header blocks with ENHANCE_YOUR_CALM" do
      with_peer(hello_server(server_settings(max_header_list_size: 1000_u32))) do |peer|
        peer.send(HTTP2::HeadersFrame.new(1_u32, Bytes.new(16_000), end_stream: true, end_headers: false))
        spawn { 5.times { peer.try_send(HTTP2::ContinuationFrame.new(1_u32, Bytes.new(16_000), end_headers: false)) } }
        peer.expect_goaway(EC::ENHANCE_YOUR_CALM)
      end
    end
  end

  describe "flow control (sending)" do
    it "blocks when the stream window is exhausted and resumes after WINDOW_UPDATE" do
      with_peer(sized_server(100), [{INITIAL_WINDOW_SIZE, 10_u32}]) do |peer|
        get(peer, 1)
        peer.expect_headers(1)
        first = peer.expect(HTTP2::DataFrame)
        first.data.size.should eq(10)
        first.end_stream?.should be_false
        peer.expect_silence
        peer.send_window_update(1, 50)
        peer.expect(HTTP2::DataFrame).data.size.should eq(50)
        peer.expect_silence
        peer.send_window_update(1, 1000)
        last = peer.expect(HTTP2::DataFrame)
        last.data.size.should eq(40)
        last.end_stream?.should be_true
      end
    end

    it "blocks when the connection window is exhausted and resumes after WINDOW_UPDATE" do
      with_peer(sized_server(100_000), [{INITIAL_WINDOW_SIZE, 1_000_000_u32}]) do |peer|
        get(peer, 1)
        peer.expect_headers(1)
        frames = read_data(peer, 1, 65_535)
        frames.none?(&.end_stream?).should be_true
        peer.expect_silence
        peer.send_window_update(0, 100_000)
        frames = read_data(peer, 1, 100_000 - 65_535)
        expect_end_stream(peer, frames)
      end
    end

    it "shares the connection window between streams" do
      with_peer(sized_server(50_000), [{INITIAL_WINDOW_SIZE, 1_000_000_u32}]) do |peer|
        get(peer, 1)
        get(peer, 3)
        per_stream = Hash(UInt32, Int32).new(0)
        while per_stream.values.sum < 65_535
          frame = peer.next_frame.not_nil!
          per_stream[frame.stream_id] += frame.data.size if frame.is_a?(HTTP2::DataFrame)
        end
        per_stream.values.sum.should eq(65_535)
        # Only an empty END_STREAM DATA frame (which needs no window) may
        # follow, from a stream that already sent all of its data.
        peer.collect(200.milliseconds).each do |frame|
          frame.as?(HTTP2::DataFrame).try(&.data.size).should eq(0) unless peer.noise?(frame)
        end
        peer.send_window_update(0, 1_000_000)
        while per_stream.values.sum < 100_000
          frame = peer.next_frame.not_nil!
          per_stream[frame.stream_id] += frame.data.size if frame.is_a?(HTTP2::DataFrame)
        end
        per_stream.should eq({1_u32 => 50_000, 3_u32 => 50_000})
      end
    end

    it "applies SETTINGS_INITIAL_WINDOW_SIZE changes to open streams, including negative windows" do
      with_peer(sized_server(100), [{INITIAL_WINDOW_SIZE, 0_u32}]) do |peer|
        get(peer, 1)
        peer.expect_headers(1)
        peer.expect_silence
        peer.send_settings([{INITIAL_WINDOW_SIZE, 60_u32}])
        peer.expect(HTTP2::DataFrame).data.size.should eq(60)
        peer.expect_silence
        # Window becomes 0 + (20 - 60) = -40.
        peer.send_settings([{INITIAL_WINDOW_SIZE, 20_u32}])
        peer.send_window_update(1, 45)
        peer.expect(HTTP2::DataFrame).data.size.should eq(5)
        peer.expect_silence
        peer.send_window_update(1, 100)
        last = peer.expect(HTTP2::DataFrame)
        last.data.size.should eq(35)
        last.end_stream?.should be_true
      end
    end

    it "treats a stream window overflow caused by SETTINGS as a connection error" do
      with_peer(echo_server) do |peer|
        post(peer, 1)
        peer.send_window_update(1, 0x7fffffff - 65_535)
        peer.send_settings([{INITIAL_WINDOW_SIZE, 65_536_u32}])
        peer.expect_goaway(EC::FLOW_CONTROL_ERROR)
      end
    end

    it "treats a connection window overflow as a connection error" do
      with_peer(hello_server) do |peer|
        peer.send_window_update(0, 0x7fffffff)
        peer.expect_goaway(EC::FLOW_CONTROL_ERROR)
      end
    end

    it "treats a stream window overflow as a stream error" do
      with_peer(echo_server) do |peer|
        post(peer, 1)
        peer.send_window_update(1, 0x7fffffff)
        peer.expect_rst(1, EC::FLOW_CONTROL_ERROR)
        expect_alive(peer)
      end
    end

    it "rejects a zero WINDOW_UPDATE increment" do
      with_peer(hello_server) do |peer|
        peer.send_window_update(0, 0)
        peer.expect_goaway(EC::PROTOCOL_ERROR)
      end
      with_peer(echo_server) do |peer|
        post(peer, 1)
        peer.send_window_update(1, 0)
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
        expect_alive(peer)
      end
    end
  end

  describe "flow control (receiving)" do
    it "sends WINDOW_UPDATE frames as the application consumes data" do
      go = Channel(Nil).new(1)
      server = HTTP2::Server.new(server_settings(initial_window_size: 1000_u32), 65_535) do |ctx|
        HTTP2Spec.receive(go)
        first = Bytes.new(600)
        ctx.request.body.read_fully(first)
        rest = ctx.request.body.gets_to_end
        ctx.response.print(600 + rest.bytesize)
      end
      with_peer(server) do |peer|
        post(peer, 1)
        peer.send_data(1, Bytes.new(1000))
        updates = peer.collect(200.milliseconds).select(HTTP2::WindowUpdateFrame)
        updates.should be_empty
        go.send(nil)
        update = peer.expect(HTTP2::WindowUpdateFrame, skip_noise: false)
        update.stream_id.should eq(1)
        update.increment.should eq(600)
        peer.send_data(1, Bytes.new(600), end_stream: true)
        peer.read_message(1)[1].should eq("1600")
      end
    end

    it "resets a stream that exceeds its flow control window" do
      read = Channel(Nil).new(1)
      server = HTTP2::Server.new(server_settings(initial_window_size: 1000_u32), 65_535) do |ctx|
        # Not reading the body keeps the window from being replenished.
        HTTP2Spec.receive(read)
        ctx.request.body.gets_to_end
      end
      with_peer(server) do |peer|
        post(peer, 1)
        peer.send_data(1, Bytes.new(600))
        peer.send_data(1, Bytes.new(401))
        peer.expect_rst(1, EC::FLOW_CONTROL_ERROR)
        expect_alive(peer)
        read.send(nil)
      end
    end

    it "counts padding against the window and credits it back immediately" do
      read = Channel(Nil).new(1)
      server = HTTP2::Server.new(server_settings(initial_window_size: 1000_u32), 65_535) do |ctx|
        # Only padding is credited while the body is not read.
        HTTP2Spec.receive(read)
        ctx.request.body.gets_to_end
      end
      with_peer(server) do |peer|
        post(peer, 1)
        peer.send_data(1, "a", padding: 256)
        peer.send_data(1, "b", padding: 256)
        update = peer.expect(HTTP2::WindowUpdateFrame, skip_noise: false)
        update.stream_id.should eq(1)
        update.increment.should eq(512)
        # 1000 - 514 + 512 = 998 octets available.
        peer.send_data(1, Bytes.new(998))
        peer.send_data(1, Bytes.new(1))
        peer.expect_rst(1, EC::FLOW_CONTROL_ERROR)
        read.send(nil)
      end
    end

    it "treats exceeding the connection window as a connection error" do
      server = HTTP2::Server.new(server_settings(max_frame_size: 100_000_u32), 65_535) do |ctx|
        ctx.request.body.gets_to_end
      end
      with_peer(server) do |peer|
        post(peer, 1)
        spawn { peer.try_send(HTTP2::DataFrame.new(1_u32, Bytes.new(65_536))) }
        peer.expect_goaway(EC::FLOW_CONTROL_ERROR)
      end
    end

    it "replenishes the connection window as data is received" do
      server = HTTP2::Server.new(server_settings, 65_535) do |ctx|
        ctx.response.print ctx.request.body.gets_to_end.bytesize
      end
      with_peer(server) do |peer|
        post(peer, 1)
        sent = 0
        10.times do
          peer.send_data(1, Bytes.new(16_384))
          sent += 16_384
        end
        peer.send_data(1, "", end_stream: true)
        peer.read_message(1)[1].should eq(sent.to_s)
      end
    end
  end

  describe "concurrency limits" do
    it "refuses streams beyond SETTINGS_MAX_CONCURRENT_STREAMS" do
      release = Channel(Nil).new(2)
      server = HTTP2::Server.new(server_settings(max_concurrent_streams: 1_u32)) do |ctx|
        HTTP2Spec.receive(release)
        ctx.response.print "ok #{ctx.request.path}"
      end
      with_peer(server) do |peer|
        get(peer, 1, "/1")
        get(peer, 3, "/3")
        peer.expect_rst(3, EC::REFUSED_STREAM)
        release.send(nil)
        peer.read_message(1)[1].should eq("ok /1")
        get(peer, 5, "/5")
        release.send(nil)
        peer.read_message(5)[1].should eq("ok /5")
      end
    end
  end

  describe "content-length" do
    it "accepts a body matching content-length" do
      with_peer(echo_server) do |peer|
        post(peer, 1, [{"content-length", "5"}])
        peer.send_data(1, "ab")
        peer.send_data(1, "cde", end_stream: true)
        peer.read_message(1)[1].should eq("abcde")
      end
    end

    it "resets when the body is shorter than content-length" do
      with_peer(echo_server) do |peer|
        post(peer, 1, [{"content-length", "10"}])
        peer.send_data(1, "short", end_stream: true)
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
        expect_alive(peer)
      end
    end

    it "resets when the body is longer than content-length" do
      with_peer(echo_server) do |peer|
        post(peer, 1, [{"content-length", "3"}])
        peer.send_data(1, "too long")
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
        expect_alive(peer)
      end
    end

    it "resets when HEADERS with END_STREAM declare a non-zero content-length" do
      with_peer(echo_server) do |peer|
        peer.send_headers(1, peer.request_fields("POST", "/", [{"content-length", "5"}]), end_stream: true)
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
        expect_alive(peer)
      end
    end

    it "resets when trailers end a body shorter than content-length" do
      with_peer(echo_server) do |peer|
        post(peer, 1, [{"content-length", "5"}])
        peer.send_data(1, "ab")
        peer.send_headers(1, [{"x-t", "1"}], end_stream: true)
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
      end
    end
  end

  describe "trailers" do
    it "resets when trailers do not carry END_STREAM" do
      with_peer(echo_server) do |peer|
        post(peer, 1)
        peer.send_headers(1, [{"x-t", "1"}], end_stream: false)
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
      end
    end

    it "resets when trailers contain pseudo-headers" do
      with_peer(echo_server) do |peer|
        post(peer, 1)
        peer.send_headers(1, [{":path", "/"}], end_stream: true)
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
      end
    end
  end

  describe "stream reset" do
    it "propagates RST_STREAM from the client to the handler" do
      result = Channel(Exception?).new(1)
      server = HTTP2::Server.new(server_settings) do |ctx|
        begin
          ctx.request.body.gets_to_end
          result.send(nil)
        rescue ex
          result.send(ex)
        end
      end
      with_peer(server) do |peer|
        post(peer, 1)
        peer.send_data(1, "abc")
        peer.send_rst(1, EC::CANCEL)
        error = HTTP2Spec.receive(result).as(HTTP2::StreamResetError)
        error.code.should eq(EC::CANCEL)
        error.remote?.should be_true
        error.stream_id.should eq(1)
        peer.expect_silence(100.milliseconds)
        expect_alive(peer)
      end
    end

    it "fails a blocked sender when the client resets the stream" do
      result = Channel(Exception?).new(1)
      server = HTTP2::Server.new(server_settings) do |ctx|
        begin
          ctx.response.write(Bytes.new(1000))
          ctx.response.close
          result.send(nil)
        rescue ex
          result.send(ex)
        end
      end
      with_peer(server, [{INITIAL_WINDOW_SIZE, 10_u32}]) do |peer|
        get(peer, 1)
        peer.expect_headers(1)
        peer.expect(HTTP2::DataFrame).data.size.should eq(10)
        peer.send_rst(1, EC::CANCEL)
        error = HTTP2Spec.receive(result).as(HTTP2::StreamResetError)
        error.code.should eq(EC::CANCEL)
        expect_alive(peer)
      end
    end

    it "sends RST_STREAM when the handler resets the stream" do
      server = HTTP2::Server.new(server_settings) do |ctx|
        ctx.stream.reset(EC::ENHANCE_YOUR_CALM)
      end
      with_peer(server) do |peer|
        get(peer, 1)
        peer.expect_rst(1, EC::ENHANCE_YOUR_CALM)
        expect_alive(peer)
      end
    end
  end

  describe "graceful shutdown" do
    it "sends GOAWAY, ignores new streams and lets active streams finish" do
      started = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      server = HTTP2::Server.new(server_settings) do |ctx|
        started.send(nil)
        HTTP2Spec.receive(release)
        ctx.response.print "finished"
      end
      with_peer(server) do |peer|
        get(peer, 1)
        HTTP2Spec.receive(started)
        closed = Channel(Nil).new(1)
        spawn do
          server.close(5.seconds)
          closed.send(nil)
        end
        expect_two_phase_goaway(peer, 1)
        get(peer, 3)
        peer.expect_silence(100.milliseconds)
        release.send(nil)
        peer.read_message(1)[1].should eq("finished")
        peer.expect_closed
        HTTP2Spec.receive(closed)
      end
    end

    it "closes immediately when there are no active streams" do
      server = hello_server
      with_peer(server) do |peer|
        get(peer, 1)
        peer.read_message(1)
        spawn { server.close }
        expect_two_phase_goaway(peer, 1)
        peer.expect_closed
      end
    end

    it "closes the connection after the shutdown timeout" do
      release = Channel(Nil).new(1)
      server = HTTP2::Server.new(server_settings) do |ctx|
        HTTP2Spec.receive(release, 10.seconds) rescue nil
      end
      with_peer(server) do |peer|
        get(peer, 1)
        peer.expect_silence(50.milliseconds)
        spawn { server.close(200.milliseconds) }
        peer.expect(HTTP2::GoawayFrame).error_code.should eq(EC::NO_ERROR)
        peer.expect_closed
        release.send(nil)
      end
    end
  end

  describe "shutdown with a peer that stops reading" do
    it "still closes the connection" do
      HTTP2Spec.bounded do
        server = HTTP2::Server.new { |ctx| ctx.response.write(Bytes.new(20_000_000)) }
        client_io, server_io = UNIXSocket.pair
        done = Channel(Nil).new(1)
        spawn { server.handle_connection(server_io); done.send(nil) }
        # Open a stream with huge windows, then never read from the socket.
        client_io.write(HTTP2::Connection::CLIENT_PREFACE)
        HTTP2::SettingsFrame.new([{INITIAL_WINDOW_SIZE, 0x7fffffff_u32}]).write(client_io)
        HTTP2::WindowUpdateFrame.new(0_u32, 0x7fffffff_u32 - 65_535).write(client_io)
        block = HTTP2::HPACK::Encoder.new.encode([{":method", "GET"}, {":scheme", "http"}, {":path", "/"}])
        HTTP2::HeadersFrame.new(1_u32, block, end_stream: true).write(client_io)
        client_io.flush
        sleep 200.milliseconds
        server.close(100.milliseconds)
        HTTP2Spec.receive(done, 3.seconds, "server connection to terminate")
        client_io.close
      end
    end
  end

  describe "client role" do
    it "sends the preface, SETTINGS and requests" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        response = Channel(HTTP2::Client::Response).new(1)
        spawn { response.send(client.get("/hello", HTTP::Headers{"X-Custom" => "1"})) }
        peer = HTTP2Spec.receive(peers)
        settings = peer.server_handshake
        settings.parameters.should contain({ENABLE_PUSH, 0_u32})
        fields, frame = peer.expect_headers(1)
        frame.end_stream?.should be_true
        fields.should eq([{":method", "GET"}, {":scheme", "http"}, {":authority", "example.com"}, {":path", "/hello"}, {"x-custom", "1"}])
        peer.send_headers(1, [{":status", "200"}, {"x-reply", "yes"}])
        peer.send_data(1, "hi", end_stream: true)
        result = HTTP2Spec.receive(response)
        result.status.should eq(200)
        result.headers["x-reply"].should eq("yes")
        result.body_text.should eq("hi")
        result.trailers.should be_nil
        client.close
      end
    end

    it "skips informational responses" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        response = Channel(HTTP2::Client::Response).new(1)
        spawn { response.send(client.get("/")) }
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        peer.expect_headers(1)
        peer.send_headers(1, [{":status", "103"}, {"link", "</a.css>"}])
        peer.send_headers(1, [{":status", "201"}], end_stream: true)
        result = HTTP2Spec.receive(response)
        result.status.should eq(201)
        result.body_text.should eq("")
        client.close
      end
    end

    it "resets a response whose body does not match content-length" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        response = Channel(HTTP2::Client::Response).new(1)
        spawn { response.send(client.get("/")) }
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        peer.expect_headers(1)
        peer.send_headers(1, [{":status", "200"}, {"content-length", "10"}])
        peer.send_data(1, "short", end_stream: true)
        result = HTTP2Spec.receive(response)
        error = expect_raises(HTTP2::StreamResetError) { result.body_text }
        error.code.should eq(EC::PROTOCOL_ERROR)
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
        client.close
      end
    end

    it "resets a stream with a malformed response" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        result = Channel(Exception?).new(1)
        spawn do
          client.get("/")
          result.send(nil)
        rescue ex
          result.send(ex)
        end
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        peer.expect_headers(1)
        peer.send_headers(1, [{"x", "no status"}], end_stream: true)
        peer.expect_rst(1, EC::PROTOCOL_ERROR)
        HTTP2Spec.receive(result).should be_a(HTTP2::StreamResetError)
        client.close
      end
    end

    it "rejects PUSH_PROMISE when push is disabled" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        result = Channel(Exception?).new(1)
        spawn do
          client.get("/")
          result.send(nil)
        rescue ex
          result.send(ex)
        end
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        peer.expect_headers(1)
        peer.send(HTTP2::PushPromiseFrame.new(1_u32, 2_u32, peer.encode([{":method", "GET"}])))
        peer.expect_goaway(EC::PROTOCOL_ERROR)
        HTTP2Spec.receive(result).should be_a(HTTP2::ConnectionClosedError)
      end
    end

    it "surfaces RST_STREAM from the server" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        result = Channel(Exception?).new(1)
        spawn do
          client.get("/")
          result.send(nil)
        rescue ex
          result.send(ex)
        end
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        peer.expect_headers(1)
        peer.send_rst(1, EC::REFUSED_STREAM)
        error = HTTP2Spec.receive(result).as(HTTP2::StreamResetError)
        error.code.should eq(EC::REFUSED_STREAM)
        error.remote?.should be_true
        client.close
      end
    end

    it "fails unprocessed streams on GOAWAY and reconnects for new requests" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        result = Channel(Exception?).new(1)
        spawn do
          client.get("/first")
          result.send(nil)
        rescue ex
          result.send(ex)
        end
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        peer.expect_headers(1)
        peer.send(HTTP2::GoawayFrame.new(0_u32, EC::NO_ERROR))
        HTTP2Spec.receive(result).should be_a(HTTP2::RefusedStreamError)
        peer.expect_closed

        response = Channel(HTTP2::Client::Response).new(1)
        spawn { response.send(client.get("/second")) }
        second = HTTP2Spec.receive(peers)
        second.server_handshake
        fields, _ = second.expect_headers(1)
        fields.should contain({":path", "/second"})
        second.send_headers(1, [{":status", "200"}], end_stream: true)
        HTTP2Spec.receive(response).status.should eq(200)
        client.close
      end
    end

    it "lets streams below the GOAWAY last stream id complete" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        response = Channel(HTTP2::Client::Response).new(1)
        spawn { response.send(client.get("/")) }
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        peer.expect_headers(1)
        peer.send(HTTP2::GoawayFrame.new(1_u32, EC::NO_ERROR))
        peer.send_headers(1, [{":status", "200"}])
        peer.send_data(1, "done", end_stream: true)
        HTTP2Spec.receive(response).body_text.should eq("done")
        peer.expect_closed
      end
    end

    it "respects the server's SETTINGS_MAX_CONCURRENT_STREAMS" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        responses = Channel(Int32).new(2)
        spawn { responses.send(client.get("/a").status) }
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake([{MAX_CONCURRENT_STREAMS, 1_u32}])
        spawn { responses.send(client.get("/b").status) }
        peer.expect_headers(1)
        peer.expect_silence(200.milliseconds)
        peer.send_headers(1, [{":status", "200"}], end_stream: true)
        fields, _ = peer.expect_headers(3)
        fields.should contain({":path", "/b"})
        peer.send_headers(3, [{":status", "202"}], end_stream: true)
        [HTTP2Spec.receive(responses), HTTP2Spec.receive(responses)].sort.should eq([200, 202])
        client.close
      end
    end

    it "pings the server" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        connection = client.connection
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        rtt = Channel(Time::Span).new(1)
        spawn { rtt.send(connection.ping) }
        ping = peer.expect(HTTP2::PingFrame)
        ping.ack?.should be_false
        peer.send(HTTP2::PingFrame.new(ping.data, ack: true))
        HTTP2Spec.receive(rtt).should be >= Time::Span.zero

        expect_raises(HTTP2::ConnectionClosedError, /timed out/) { connection.ping(100.milliseconds) }
        peer.expect(HTTP2::PingFrame)
        client.close
      end
    end

    it "fails pending pings when the connection closes" do
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client
        connection = client.connection
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        result = Channel(Exception?).new(1)
        spawn do
          connection.ping
          result.send(nil)
        rescue ex
          result.send(ex)
        end
        peer.expect(HTTP2::PingFrame)
        peer.close
        HTTP2Spec.receive(result).should be_a(HTTP2::ConnectionClosedError)
      end
    end

    it "returns flow control credit to the server as the response body is read" do
      settings = HTTP2::Settings.new(enable_push: false, initial_window_size: 1000_u32)
      HTTP2Spec.bounded do
        client, peers = HTTP2Spec.raw_server_client(settings)
        response = Channel(HTTP2::Client::Response).new(1)
        spawn { response.send(client.get("/")) }
        peer = HTTP2Spec.receive(peers)
        peer.server_handshake
        peer.expect_headers(1)
        peer.send_headers(1, [{":status", "200"}])
        peer.send_data(1, Bytes.new(1000))
        result = HTTP2Spec.receive(response)
        peer.collect(100.milliseconds).select(HTTP2::WindowUpdateFrame).select { |f| f.stream_id == 1 }.should be_empty
        result.body.read_fully(Bytes.new(1000))
        update = peer.expect(HTTP2::WindowUpdateFrame, skip_noise: false)
        update.stream_id.should eq(1)
        update.increment.should eq(1000)
        peer.send_data(1, Bytes.new(1000), end_stream: true)
        result.body.gets_to_end.bytesize.should eq(1000)
        client.close
      end
    end
  end
end
