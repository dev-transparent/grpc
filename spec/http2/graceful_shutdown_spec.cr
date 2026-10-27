require "./support"

private alias EC = HTTP2::ErrorCode

private def get_path(peer, id, end_stream = true)
  peer.send_headers(id, peer.request_fields("GET", "/#{id}"), end_stream: end_stream)
end

private def path_server(opts = HTTP2::Server.default_options)
  HTTP2::Server.new(HTTP2::Server.default_settings, options: opts) { |ctx| ctx.response.print ctx.request.path }
end

private def client_with_peer
  client, peers = HTTP2Spec.raw_server_client
  connection = client.connection
  peer = HTTP2Spec.receive(peers)
  peer.server_handshake
  {client, connection, peer, peers}
end

describe "HTTP2 graceful shutdown" do
  describe "server" do
    it "processes streams opened between the first GOAWAY and the PING ACK" do
      server = path_server
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          closed = Channel(Nil).new(1)
          spawn { server.close(5.seconds); closed.send(nil) }
          first = peer.expect(HTTP2::GoawayFrame)
          first.last_stream_id.should eq(HTTP2::MAX_STREAM_ID)
          ping = peer.expect(HTTP2::PingFrame)
          # The client opened a stream before it saw the GOAWAY.
          get_path(peer, 1)
          get_path(peer, 3)
          peer.send(HTTP2::PingFrame.new(ping.data, ack: true))
          bodies = Hash(UInt32, String).new("")
          ended = Set(UInt32).new
          final = nil
          until final && ended.size == 2
            frame = peer.next_frame || raise "Connection closed early"
            case frame
            when HTTP2::GoawayFrame then final = frame
            when HTTP2::HeadersFrame
              peer.decoder.decode(frame.fragment)
              ended << frame.stream_id if frame.end_stream?
            when HTTP2::DataFrame
              bodies[frame.stream_id] += String.new(frame.data)
              ended << frame.stream_id if frame.end_stream?
            end
          end
          final.last_stream_id.should eq(3)
          final.error_code.should eq(EC::NO_ERROR)
          bodies.should eq({1_u32 => "/1", 3_u32 => "/3"})
          peer.expect_closed
          HTTP2Spec.receive(closed)
        end
      end
    end

    it "sends the final GOAWAY when the PING is not acknowledged in time" do
      server = path_server(HTTP2::ConnectionOptions.new(shutdown_ping_timeout: 200.milliseconds))
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          get_path(peer, 1)
          peer.read_message(1)
          started = Time.instant
          spawn { server.close(5.seconds) }
          peer.expect(HTTP2::GoawayFrame).last_stream_id.should eq(HTTP2::MAX_STREAM_ID)
          peer.expect(HTTP2::PingFrame)
          final = peer.expect(HTTP2::GoawayFrame)
          final.last_stream_id.should eq(1)
          (Time.instant - started).should be >= 150.milliseconds
          peer.expect_closed
        end
      end
    end

    it "closes connections whose streams outlive the shutdown timeout" do
      server = HTTP2::Server.new { |ctx| ctx.request.body.gets_to_end }
      HTTP2Spec.bounded do
        HTTP2Spec.with_raw_client(server) do |peer|
          peer.handshake
          get_path(peer, 1, end_stream: false)
          peer.expect_silence(50.milliseconds)
          spawn { server.close(300.milliseconds) }
          peer.expect(HTTP2::GoawayFrame)
          ping = peer.expect(HTTP2::PingFrame)
          peer.send(HTTP2::PingFrame.new(ping.data, ack: true))
          peer.expect(HTTP2::GoawayFrame).last_stream_id.should eq(1)
          peer.expect_closed
        end
      end
    end

    it "loses no requests while connections are repeatedly drained under load" do
      opts = HTTP2::ConnectionOptions.new(max_connection_age: 50.milliseconds)
      server = path_server(opts)
      HTTP2Spec.bounded(30.seconds) do
        HTTP2Spec.with_server(server) do |client|
          results = Channel(Exception?).new(400)
          8.times do |worker|
            spawn do
              50.times do |i|
                path = "/#{worker}/#{i}"
                body = client.get(path).body_text
                results.send(body == path ? nil : Exception.new("Unexpected body #{body}"))
              rescue e
                results.send(e)
              end
            end
          end
          errors = Array.new(400) { HTTP2Spec.receive(results, 20.seconds) }.compact
          errors.should be_empty
        end
      end
    end
  end

  describe "client" do
    it "fails streams above the GOAWAY last stream identifier with RefusedStreamError" do
      HTTP2Spec.bounded do
        client, connection, peer, peers = client_with_peer
        first = connection.open_stream(peer.request_fields, end_stream: true)
        second = connection.open_stream(peer.request_fields, end_stream: true)
        peer.expect_headers(1)
        peer.expect_headers(3)
        peer.send(HTTP2::GoawayFrame.new(1_u32, EC::NO_ERROR))
        expect_raises(HTTP2::RefusedStreamError) { second.headers }
        connection.available?.should be_false
        peer.send_headers(1, [{":status", "200"}], end_stream: true)
        first.headers.should eq([{":status", "200"}])
        first.error.should be_nil
        peer.expect_closed

        # New requests use a new connection.
        response = Channel(Int32).new(1)
        spawn { response.send(client.get("/").status) }
        peer2 = HTTP2Spec.receive(peers)
        peer2.server_handshake
        peer2.expect_headers(1)
        peer2.send_headers(1, [{":status", "204"}], end_stream: true)
        HTTP2Spec.receive(response).should eq(204)
        client.close
      end
    end

    it "keeps streams after the first GOAWAY of a two-phase shutdown but opens new ones elsewhere" do
      HTTP2Spec.bounded do
        client, connection, peer, peers = client_with_peer
        stream = connection.open_stream(peer.request_fields, end_stream: true)
        peer.expect_headers(1)
        peer.send(HTTP2::GoawayFrame.new(HTTP2::MAX_STREAM_ID, EC::NO_ERROR))
        HTTP2Spec.eventually { !connection.available? }
        expect_raises(HTTP2::RefusedStreamError) { connection.open_stream(peer.request_fields) }
        peer.send(HTTP2::GoawayFrame.new(1_u32, EC::NO_ERROR))
        peer.send_headers(1, [{":status", "200"}], end_stream: true)
        stream.headers.should eq([{":status", "200"}])
        peer.expect_closed

        response = Channel(Int32).new(1)
        spawn { response.send(client.get("/").status) }
        peer2 = HTTP2Spec.receive(peers)
        peer2.server_handshake
        peer2.expect_headers(1)
        peer2.send_headers(1, [{":status", "200"}], end_stream: true)
        HTTP2Spec.receive(response).should eq(200)
        client.close
      end
    end

    it "sends a single GOAWAY when the client shuts down" do
      HTTP2Spec.bounded do
        client, connection, peer, _ = client_with_peer
        spawn { client.close }
        goaway = peer.expect(HTTP2::GoawayFrame)
        goaway.last_stream_id.should eq(0)
        peer.expect_closed
        HTTP2Spec.within { connection.wait_closed }
      end
    end
  end
end
