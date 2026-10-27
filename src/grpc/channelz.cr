require "../grpc"
require "./channelz/grpc/channelz/v1/channelz_grpc.pb"

module GRPC
  # The channelz service (`grpc.channelz.v1.Channelz`), which exposes live
  # runtime information about the channels, subchannels, servers and sockets
  # of the process for debugging tools.
  #
  # ```
  # require "grpc/channelz"
  #
  # server.handle(GRPC::Channelz.new)
  # ```
  #
  # Every `GRPC::Channel` and `GRPC::Server` is tracked automatically
  # (through weak references, so tracking never keeps them alive).
  # Subchannels do not record call counts; their sockets do.
  class Channelz < ::Grpc::Channelz::V1::Channelz::Service
    alias Pb = ::Grpc::Channelz::V1

    DEFAULT_MAX_RESULTS = 100

    def get_top_channels(request, context)
      channels = ChannelzRegistry.channels.reject(&.state.shutdown?)
      page, last = paginate(channels, request.start_channel_id, request.max_results, &.channelz_id)
      Pb::GetTopChannelsResponse.new(channel: page.map { |channel| channel_message(channel) }, end_: last)
    end

    def get_servers(request, context)
      servers = ChannelzRegistry.servers.reject(&.closed?)
      page, last = paginate(servers, request.start_server_id, request.max_results, &.channelz_id)
      Pb::GetServersResponse.new(server: page.map { |server| server_message(server) }, end_: last)
    end

    def get_server(request, context)
      server = find_server(request.server_id) || raise Error.new(:not_found, "No server with id #{request.server_id}")
      Pb::GetServerResponse.new(server: server_message(server))
    end

    def get_server_sockets(request, context)
      server = find_server(request.server_id) || raise Error.new(:not_found, "No server with id #{request.server_id}")
      page, last = paginate(server.http2.connections, request.start_socket_id, request.max_results, &.id)
      Pb::GetServerSocketsResponse.new(socket_ref: page.map { |connection| socket_ref(connection) }, end_: last)
    end

    def get_channel(request, context)
      channel = ChannelzRegistry.channels.find(&.channelz_id.== request.channel_id) ||
                raise Error.new(:not_found, "No channel with id #{request.channel_id}")
      Pb::GetChannelResponse.new(channel: channel_message(channel))
    end

    def get_subchannel(request, context)
      ChannelzRegistry.channels.each do |channel|
        if subchannel = channel.subchannels.find(&.channelz_id.== request.subchannel_id)
          return Pb::GetSubchannelResponse.new(subchannel: subchannel_message(subchannel))
        end
      end
      raise Error.new(:not_found, "No subchannel with id #{request.subchannel_id}")
    end

    def get_socket(request, context)
      if connection = all_connections.find(&.id.== request.socket_id)
        return Pb::GetSocketResponse.new(socket: socket_message(connection, summary: request.summary))
      end
      ChannelzRegistry.servers.each do |server|
        if listener = server.http2.listeners.find { |(id, _)| id == request.socket_id }
          id, local = listener
          return Pb::GetSocketResponse.new(socket: Pb::Socket.new(
            ref: Pb::SocketRef.new(socket_id: id, name: local.to_s), data: Pb::SocketData.new,
            local: address(local.to_s)))
        end
      end
      raise Error.new(:not_found, "No socket with id #{request.socket_id}")
    end

    # --- Messages ---

    private def channel_message(channel : GRPC::Channel) : Pb::Channel
      Pb::Channel.new(
        ref: Pb::ChannelRef.new(channel_id: channel.channelz_id, name: channel.target),
        data: Pb::ChannelData.new(
          state: connectivity(channel.state),
          target: channel.target,
          calls_started: channel.call_metrics.started.get,
          calls_succeeded: channel.call_metrics.succeeded.get,
          calls_failed: channel.call_metrics.failed.get,
          last_call_started_timestamp: timestamp(channel.call_metrics.last_started.get),
          trace: trace(channel.created_at),
        ),
        subchannel_ref: channel.subchannels.map { |subchannel| subchannel_ref(subchannel) },
      )
    end

    private def subchannel_message(subchannel : GRPC::Subchannel) : Pb::Subchannel
      sockets = subchannel.connection.try { |connection| [socket_ref(connection)] } || [] of Pb::SocketRef
      Pb::Subchannel.new(
        ref: subchannel_ref(subchannel),
        data: Pb::ChannelData.new(state: connectivity(subchannel.state), target: subchannel.address.to_s,
          trace: trace(subchannel.created_at)),
        socket_ref: sockets,
      )
    end

    private def server_message(server : GRPC::Server) : Pb::Server
      listen = server.http2.listeners.map do |(id, address)|
        Pb::SocketRef.new(socket_id: id, name: address.to_s)
      end
      Pb::Server.new(
        ref: Pb::ServerRef.new(server_id: server.channelz_id, name: "server-#{server.channelz_id}"),
        data: Pb::ServerData.new(
          calls_started: server.call_metrics.started.get,
          calls_succeeded: server.call_metrics.succeeded.get,
          calls_failed: server.call_metrics.failed.get,
          last_call_started_timestamp: timestamp(server.call_metrics.last_started.get),
          trace: trace(server.created_at),
        ),
        listen_socket: listen,
      )
    end

    private def socket_message(connection : HTTP2::Connection, summary : Bool) : Pb::Socket
      metrics = connection.metrics
      data = Pb::SocketData.new(
        streams_started: metrics.streams_started.get,
        streams_succeeded: metrics.streams_succeeded.get,
        streams_failed: metrics.streams_failed.get,
        messages_sent: metrics.messages_sent.get,
        messages_received: metrics.messages_received.get,
        keep_alives_sent: metrics.keepalives_sent.get,
        last_local_stream_created_timestamp: timestamp(metrics.last_local_stream_created.get),
        last_remote_stream_created_timestamp: timestamp(metrics.last_remote_stream_created.get),
        last_message_sent_timestamp: timestamp(metrics.last_message_sent.get),
        last_message_received_timestamp: timestamp(metrics.last_message_received.get),
      )
      unless summary
        data.local_flow_control_window = Google::Protobuf::Int64Value.new(value: connection.receive_window)
        data.remote_flow_control_window = Google::Protobuf::Int64Value.new(value: connection.send_window)
        data.received_goaway_error = metrics.goaway_error_code.try { |code| Google::Protobuf::UInt32Value.new(value: code) }
        data.peer_max_concurrent_streams = connection.remote_settings.max_concurrent_streams || 0_u32
      end
      Pb::Socket.new(
        ref: socket_ref(connection),
        data: data,
        local: address(connection.local_address),
        remote: address(connection.remote_address),
        remote_name: connection.remote_address || "",
      )
    end

    private def socket_ref(connection : HTTP2::Connection) : Pb::SocketRef
      Pb::SocketRef.new(socket_id: connection.id, name: "#{connection.local_address} -> #{connection.remote_address}")
    end

    private def subchannel_ref(subchannel : GRPC::Subchannel) : Pb::SubchannelRef
      Pb::SubchannelRef.new(subchannel_id: subchannel.channelz_id, name: subchannel.address.to_s)
    end

    private def connectivity(state : ConnectivityState) : Pb::ChannelConnectivityState
      value = case state
              in .idle?              then Pb::ChannelConnectivityState::State::IDLE
              in .connecting?        then Pb::ChannelConnectivityState::State::CONNECTING
              in .ready?             then Pb::ChannelConnectivityState::State::READY
              in .transient_failure? then Pb::ChannelConnectivityState::State::TRANSIENT_FAILURE
              in .shutdown?          then Pb::ChannelConnectivityState::State::SHUTDOWN
              end
      Pb::ChannelConnectivityState.new(state: value)
    end

    # Parses "ip:port" / "[ipv6]:port" / UNIX paths into a channelz address.
    private def address(text : String?) : Pb::Address?
      return nil unless text
      if text.starts_with?('/') || text.starts_with?("unix:")
        return Pb::Address.new(uds_address: Pb::Address::UdsAddress.new(filename: text.lchop("unix:")))
      end
      host, _, port = text.rpartition(':')
      host = host.lchop('[').rchop(']')
      ip = Socket::IPAddress.new(host, port.to_i? || 0) rescue nil
      if ip
        Pb::Address.new(tcpip_address: Pb::Address::TcpIpAddress.new(ip_address: ip_bytes(host), port: ip.port))
      else
        Pb::Address.new(other_address: Pb::Address::OtherAddress.new(name: text))
      end
    end

    private def ip_bytes(host : String) : Bytes
      if host.includes?(':')
        # Expand an IPv6 address into 16 bytes.
        head, _, tail = host.partition("::")
        left = head.empty? ? [] of String : head.split(':')
        right = tail.empty? ? [] of String : tail.split(':')
        groups = left + Array.new(8 - left.size - right.size, "0") + right
        bytes = Bytes.new(16)
        groups.each_with_index do |group, i|
          value = group.to_i(16)
          bytes[i * 2] = (value >> 8).to_u8
          bytes[i * 2 + 1] = (value & 0xff).to_u8
        end
        bytes
      else
        Bytes.new(4) { |i| host.split('.')[i].to_u8 }
      end
    end

    private def trace(created_at : Time) : Pb::ChannelTrace
      Pb::ChannelTrace.new(creation_timestamp: Google::Protobuf::Timestamp.from_time(created_at))
    end

    private def timestamp(nanos : Int64) : Google::Protobuf::Timestamp?
      return nil if nanos == 0
      Google::Protobuf::Timestamp.new(seconds: nanos // 1_000_000_000, nanos: (nanos % 1_000_000_000).to_i32)
    end

    # --- Lookup ---

    private def find_server(id : Int64) : GRPC::Server?
      ChannelzRegistry.servers.find(&.channelz_id.== id)
    end

    private def all_connections : Array(HTTP2::Connection)
      connections = [] of HTTP2::Connection
      ChannelzRegistry.servers.each { |server| connections.concat(server.http2.connections) }
      ChannelzRegistry.channels.each do |channel|
        channel.subchannels.each { |subchannel| subchannel.connection.try { |c| connections << c } }
      end
      connections
    end

    # Returns the items with id >= *start* (sorted by id), up to *max*
    # results, and whether this is the last page.
    private def paginate(items : Array(T), start : Int64, max : Int64, &id : T -> Int64) : {Array(T), Bool} forall T
      max = DEFAULT_MAX_RESULTS.to_i64 if max <= 0
      sorted = items.select { |item| id.call(item) >= start }.sort_by { |item| id.call(item) }
      page = sorted.first(max)
      {page, sorted.size <= max}
    end
  end
end
