require "./grpc_helper"
require "../../src/grpc/channelz"

private alias Pb = Grpc::Channelz::V1

describe GRPC::Channelz do
  it "reports channels, subchannels, servers and sockets" do
    server = GRPC::Server.new
    server.handle(GRPC::Channelz.new)
    GRPCSpec.with_server(server: server) do |h|
      3.times { h.client.unary(GrpcSpec::EchoRequest.new(message: "z")) }
      expect_raises(GRPC::Error) { h.client.unary(GrpcSpec::EchoRequest.new(status_code: 5)) }

      channelz = Pb::Channelz::Client.new(h.channel)

      # The harness channel (other specs may have left many channels alive,
      # so look it up by id rather than in the first page).
      channel = channelz.get_channel(Pb::GetChannelRequest.new(channel_id: h.channel.channelz_id)).channel.not_nil!
      channel.data.not_nil!.target.should eq(h.address)
      data = channel.data.not_nil!
      data.state.not_nil!.state.should eq(Pb::ChannelConnectivityState::State::READY)
      data.calls_started.should be >= 4
      data.calls_failed.should be >= 1
      data.last_call_started_timestamp.should_not be_nil

      found = channelz.get_channel(Pb::GetChannelRequest.new(channel_id: channel.ref.not_nil!.channel_id)).channel.not_nil!
      subchannel_id = found.subchannel_ref.first.subchannel_id
      subchannel = channelz.get_subchannel(Pb::GetSubchannelRequest.new(subchannel_id: subchannel_id)).subchannel.not_nil!
      subchannel.data.not_nil!.state.not_nil!.state.should eq(Pb::ChannelConnectivityState::State::READY)
      client_socket_id = subchannel.socket_ref.first.socket_id

      client_socket = channelz.get_socket(Pb::GetSocketRequest.new(socket_id: client_socket_id)).socket.not_nil!
      socket_data = client_socket.data.not_nil!
      socket_data.streams_started.should be >= 4
      socket_data.messages_sent.should be >= 4
      socket_data.messages_received.should be >= 3
      socket_data.local_flow_control_window.not_nil!.value.should be > 0
      client_socket.remote.not_nil!.tcpip_address.not_nil!.port.should eq(h.address.split(':').last.to_i)
      client_socket.remote.not_nil!.tcpip_address.not_nil!.ip_address.should eq(Bytes[127, 0, 0, 1])

      # The server side.
      server_message = channelz.get_server(Pb::GetServerRequest.new(server_id: server.channelz_id)).server.not_nil!
      server_message.data.not_nil!.calls_succeeded.should be >= 3
      server_message.data.not_nil!.calls_failed.should be >= 1
      server_message.listen_socket.first.name.should eq(h.address)

      sockets = channelz.get_server_sockets(Pb::GetServerSocketsRequest.new(server_id: server.channelz_id))
      sockets.end_.should be_true
      server_socket = channelz.get_socket(Pb::GetSocketRequest.new(socket_id: sockets.socket_ref.first.socket_id)).socket.not_nil!
      server_socket.data.not_nil!.last_remote_stream_created_timestamp.should_not be_nil
    end
  end

  it "paginates and reports unknown ids" do
    server = GRPC::Server.new
    server.handle(GRPC::Channelz.new)
    extra = Array.new(3) { GRPC::Channel.new("127.0.0.1:1") }
    GRPCSpec.with_server(server: server) do |h|
      channelz = Pb::Channelz::Client.new(h.channel)
      first = channelz.get_top_channels(Pb::GetTopChannelsRequest.new(max_results: 2))
      first.channel.size.should eq(2)
      first.end_.should be_false
      next_id = first.channel.last.ref.not_nil!.channel_id + 1
      rest = channelz.get_top_channels(Pb::GetTopChannelsRequest.new(start_channel_id: next_id, max_results: 1000))
      rest.end_.should be_true
      (first.channel + rest.channel).map(&.ref.not_nil!.channel_id).uniq.size.should eq(first.channel.size + rest.channel.size)

      GRPCSpec.expect_status(GRPC::StatusCode::NotFound) { channelz.get_channel(Pb::GetChannelRequest.new(channel_id: -1_i64)) }
      GRPCSpec.expect_status(GRPC::StatusCode::NotFound) { channelz.get_socket(Pb::GetSocketRequest.new(socket_id: -1_i64)) }
      GRPCSpec.expect_status(GRPC::StatusCode::NotFound) { channelz.get_server(Pb::GetServerRequest.new(server_id: -1_i64)) }
    end
    extra.each &.shutdown
  end
end
