require "./support"

private alias EC = HTTP2::ErrorCode

private def client_and_peer(opts = HTTP2::Client.default_options)
  client, peers = HTTP2Spec.raw_server_client(options: opts)
  connection = client.connection
  peer = HTTP2Spec.receive(peers)
  {client, connection, peer}
end

describe "HTTP2::Connection notifications" do
  it "reports when the peer's SETTINGS arrived" do
    HTTP2Spec.bounded do
      _, connection, peer = client_and_peer
      connection.remote_settings_received?.should be_false
      connection.wait_for_remote_settings(50.milliseconds).should be_false
      waiter = Channel(Bool).new(1)
      spawn { waiter.send(connection.wait_for_remote_settings(2.seconds)) }
      peer.server_handshake
      HTTP2Spec.receive(waiter).should be_true
      connection.remote_settings_received?.should be_true
      connection.wait_for_remote_settings(1.millisecond).should be_true
      connection.close
    end
  end

  it "stops waiting for SETTINGS when the connection closes" do
    HTTP2Spec.bounded do
      _, connection, peer = client_and_peer
      waiter = Channel(Bool).new(1)
      spawn { waiter.send(connection.wait_for_remote_settings(5.seconds)) }
      sleep 20.milliseconds
      peer.close
      HTTP2Spec.receive(waiter, 2.seconds).should be_false
    end
  end

  it "notifies GOAWAY frames" do
    HTTP2Spec.bounded do
      _, connection, peer = client_and_peer
      peer.server_handshake
      stream = connection.open_stream(peer.request_fields, end_stream: true)
      goaways = Channel(HTTP2::GoawayFrame).new(2)
      connection.on_goaway { |frame| goaways.send(frame) }
      connection.on_goaway { |frame| goaways.send(frame) }
      peer.send(HTTP2::GoawayFrame.new(HTTP2::MAX_STREAM_ID, EC::NO_ERROR))
      2.times { HTTP2Spec.receive(goaways).last_stream_id.should eq(HTTP2::MAX_STREAM_ID) }
      connection.available?.should be_false
      stream.closed?.should be_false
      peer.send(HTTP2::GoawayFrame.new(0_u32, EC::NO_ERROR))
      HTTP2Spec.receive(goaways).last_stream_id.should eq(0)
      expect_raises(HTTP2::RefusedStreamError) { stream.headers }
    end
  end

  it "supports several close callbacks next to the on_close property" do
    HTTP2Spec.bounded do
      _, connection, peer = client_and_peer
      peer.server_handshake
      closed = Channel(String).new(4)
      connection.on_close = ->(_c : HTTP2::Connection) { closed.send("property"); nil }
      connection.on_close { closed.send("first") }
      connection.on_close { closed.send("second") }
      peer.close
      Array.new(3) { HTTP2Spec.receive(closed) }.sort.should eq(["first", "property", "second"])
      connection.on_close { closed.send("late") }
      HTTP2Spec.receive(closed).should eq("late")
    end
  end

  it "configures keepalive after construction" do
    HTTP2Spec.bounded do
      client, connection, peer = client_and_peer
      peer.server_handshake
      connection.configure_keepalive(50.milliseconds, 1.second, permit_without_calls: true)
      connection.options.keepalive_time.should eq(50.milliseconds)
      ping = peer.expect(HTTP2::PingFrame)
      ping.ack?.should be_false
      peer.send(HTTP2::PingFrame.new(ping.data, ack: true))
      connection.configure_keepalive(nil)
      peer.collect(200.milliseconds).count(HTTP2::PingFrame).should be <= 1
      client.close
    end
  end
end
