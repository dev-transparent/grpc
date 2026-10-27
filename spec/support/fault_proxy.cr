require "socket"

# A TCP proxy for tests that injects network faults between a client and a
# server. Only depends on the standard library.
#
# Each direction (`upstream`: client to server, `downstream`: server to
# client) has independent knobs that can be changed at any time:
#
# * `latency`: delay added to every piece of data (throughput is not
#   limited by it: data keeps being read while earlier data is delayed)
# * `bandwidth`: maximum octets per second
# * `chunk_size`: deliver data in writes of at most this many octets (1
#   delivers byte by byte, each in its own TCP segment)
# * `paused`: stop delivering (data is buffered, then the sender blocks)
# * `black_hole`: silently discard all data
#
# Connection level faults: `#drop_connections` abruptly closes every proxied
# connection (with a TCP RST when *rst* is set) and `black_hole_connections`
# accepts new connections without ever connecting them to the server.
#
# ```
# proxy = FaultProxy.new("127.0.0.1", server_port)
# proxy.downstream.latency = 50.milliseconds
# proxy.upstream.chunk_size = 1
# client = HTTP2::Client.new("127.0.0.1", proxy.port)
# ```
class FaultProxy
  # Fault settings of one direction. Thread safe.
  class Direction
    @mutex = Mutex.new
    @latency = Time::Span.zero
    @bandwidth : Int32? = nil
    @chunk_size : Int32? = nil
    @paused = false
    @black_hole = false

    {% for name, type in {latency: "Time::Span", bandwidth: "Int32?", chunk_size: "Int32?"} %}
      def {{name.id}} : {{type.id}}
        @mutex.synchronize { @{{name.id}} }
      end

      def {{name.id}}=(value : {{type.id}}) : {{type.id}}
        @mutex.synchronize { @{{name.id}} = value }
      end
    {% end %}

    {% for name in %w(paused black_hole) %}
      def {{name.id}}? : Bool
        @mutex.synchronize { @{{name.id}} }
      end

      def {{name.id}}=(value : Bool) : Bool
        @mutex.synchronize { @{{name.id}} = value }
      end
    {% end %}

    # Restores the defaults (no faults).
    def reset : Nil
      @mutex.synchronize do
        @latency = Time::Span.zero
        @bandwidth = nil
        @chunk_size = nil
        @paused = false
        @black_hole = false
      end
    end
  end

  # Data read from one side, to be delivered to the other at `deliver_at`.
  private record Packet, data : Bytes?, deliver_at : Time::Instant

  # A proxied client/server socket pair.
  private class Link
    getter client : TCPSocket
    getter server : TCPSocket?

    @finished = Atomic(Int32).new(0)

    def initialize(@client : TCPSocket, @server : TCPSocket?)
    end

    # Records that one direction reached EOF; returns `true` once both did.
    def finish_direction : Bool
      @finished.add(1) == 1
    end

    def close(rst : Bool) : Nil
      {@client, @server}.each do |socket|
        next unless socket
        socket.linger = 0 if rst rescue nil
        socket.close rescue nil
      end
    end
  end

  getter upstream = Direction.new
  getter downstream = Direction.new
  # Accept new connections but never connect them to the server.
  property? black_hole_connections = false

  @server : TCPServer
  @links = Set(Link).new
  @mutex = Mutex.new
  @closed = false
  @accepted = Atomic(Int32).new(0)

  def initialize(@target_host : String, @target_port : Int32, host : String = "127.0.0.1")
    @server = TCPServer.new(host, 0)
    proxy_spawn("fault-proxy-accept") { accept_loop }
  end

  private def proxy_spawn(name : String, &block : ->) : Nil
    spawn(name: name, &block)
  end

  # Kept as a seam for running socket operations elsewhere.
  private def on_proxy_thread(&) : Nil
    yield
  end

  def port : Int32
    @server.local_address.port
  end

  def address : Socket::IPAddress
    @server.local_address
  end

  # The number of connections accepted so far.
  def accepted : Int32
    @accepted.get
  end

  # The number of currently proxied connections.
  def connections : Int32
    @mutex.synchronize { @links.size }
  end

  # Pauses (stalls) both directions.
  def pause : Nil
    upstream.paused = true
    downstream.paused = true
  end

  def resume : Nil
    upstream.paused = false
    downstream.paused = false
  end

  # Removes all faults.
  def reset : Nil
    upstream.reset
    downstream.reset
    self.black_hole_connections = false
  end

  # Abruptly closes every proxied connection. With *rst* the sockets are
  # closed with SO_LINGER 0 so the peers receive a TCP RST.
  def drop_connections(rst : Bool = true) : Nil
    links = @mutex.synchronize do
      list = @links.to_a
      @links.clear
      list
    end
    on_proxy_thread { links.each &.close(rst) }
  end

  # Stops accepting and drops all connections.
  def close : Nil
    @mutex.synchronize { @closed = true }
    on_proxy_thread { @server.close rescue nil }
    drop_connections
  end

  private def accept_loop : Nil
    while client = @server.accept?
      @accepted.add(1)
      spawn_link(client)
    end
  rescue IO::Error
  end

  # Each fiber must capture its own socket, not the loop variable.
  private def spawn_link(client : TCPSocket) : Nil
    proxy_spawn("fault-proxy-link") { handle(client) }
  end

  private def handle(client : TCPSocket) : Nil
    client.tcp_nodelay = true
    client.sync = true
    if black_hole_connections?
      register(Link.new(client, nil))
      return
    end
    server = TCPSocket.new(@target_host, @target_port)
    server.tcp_nodelay = true
    server.sync = true
    link = Link.new(client, server)
    return unless register(link)
    proxy_spawn("fault-proxy-up") { pump(client, server, upstream, link) }
    proxy_spawn("fault-proxy-down") { pump(server, client, downstream, link) }
  rescue IO::Error | Socket::Error
    client.close rescue nil
  end

  private def register(link : Link) : Bool
    @mutex.synchronize do
      if @closed
        link.close(rst: true)
        return false
      end
      @links << link
    end
    true
  end

  private def unregister(link : Link) : Nil
    @mutex.synchronize { @links.delete(link) }
  end

  # Copies *src* to *dst* applying *direction*'s faults. The reading and the
  # delayed delivery run in separate fibers connected by a bounded channel,
  # which provides backpressure.
  private def pump(src : TCPSocket, dst : TCPSocket, direction : Direction, link : Link) : Nil
    packets = Channel(Packet).new(64)
    proxy_spawn("fault-proxy-deliver") { deliver(packets, dst, direction, link) }
    copy(src, packets, direction)
  rescue IO::Error | Channel::ClosedError
    packets.try &.close
    abort(link)
  end

  private def copy(src : TCPSocket, packets : Channel(Packet), direction : Direction) : Nil
    buffer = Bytes.new(16_384)
    loop do
      read = src.read(buffer)
      if read == 0
        packets.send(Packet.new(nil, Time.instant + direction.latency))
        break
      end
      packets.send(Packet.new(buffer[0, read].dup, Time.instant + direction.latency))
    end
  end

  private def deliver(packets : Channel(Packet), dst : TCPSocket, direction : Direction, link : Link) : Nil
    while packet = packets.receive?
      delay = packet.deliver_at - Time.instant
      sleep delay if delay > Time::Span.zero
      data = packet.data
      unless data
        dst.close_write rescue nil
        if link.finish_direction
          unregister(link)
          link.close(rst: false)
        end
        return
      end
      offset = 0
      while offset < data.size
        while direction.paused?
          sleep 2.milliseconds
        end
        size = Math.min(direction.chunk_size || data.size, data.size - offset)
        unless direction.black_hole?
          dst.write(data[offset, size])
          dst.flush
        end
        offset += size
        if bandwidth = direction.bandwidth
          sleep (size / bandwidth).seconds
        end
      end
    end
  rescue IO::Error
    packets.close
    abort(link)
  end

  private def abort(link : Link) : Nil
    unregister(link)
    link.close(rst: false)
  end
end
