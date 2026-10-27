require "./runtime"

module Sim
  # Wakes up fibers waiting for a condition (single-threaded: checking a
  # condition and then waiting cannot race with a broadcast).
  class Signal
    @waiters = [] of ::Channel(Nil)

    def wait : Nil
      channel = ::Channel(Nil).new(1)
      @waiters << channel
      channel.receive
    end

    def broadcast : Nil
      waiters = @waiters
      @waiters = [] of ::Channel(Nil)
      waiters.each { |channel| channel.send(nil) }
    end
  end

  # A simulated network of hosts exchanging TCP-like byte streams in memory.
  #
  # Delivery is ordered and reliable per connection (like TCP) but delayed
  # by seeded latency, jitter and bandwidth, split into random segment
  # sizes, and bounded by a per-direction window (writers block when the
  # receiver does not keep up). Faults: refused connects, connect timeouts,
  # partitions (one or both directions; segments are held until healed),
  # connection resets, and latency spikes.
  class Network
    # Base one-way latency.
    property latency : Time::Span = 200.microseconds
    # Uniform extra latency in [0, jitter).
    property jitter : Time::Span = 300.microseconds
    # Bytes per second per direction (`nil`: unlimited).
    property bandwidth : Int64? = 1_000_000_000_i64
    # Largest segment; writes are split into random sizes up to this.
    property max_segment : Int32 = 16_384
    # Bytes in flight plus unread before writers block (the TCP window).
    property window : Int32 = 1 << 20
    # How long connects to partitioned hosts take to fail.
    property connect_timeout : Time::Span = 3.seconds

    getter trace : Trace
    @listeners = {} of String => Proc(Endpoint, Nil)
    @blocked = Set({String, String}).new
    @links = [] of Link
    @heal_signal = Signal.new
    @next_port = 40_000

    def initialize(@trace : Trace)
    end

    # Accepts connections to *address* (`"host:port"`).
    def listen(address : String, &on_accept : Endpoint ->) : Nil
      @listeners[address] = on_accept
    end

    # Stops accepting connections to *address* (new connects are refused).
    def unlisten(address : String) : Nil
      @listeners.delete(address)
    end

    def listening?(address : String) : Bool
      @listeners.has_key?(address)
    end

    # Connects from *from_host* to *address*, taking one round trip.
    def connect(from_host : String, address : String) : Endpoint
      to_host = Network.host(address)
      if blocked?(from_host, to_host) || blocked?(to_host, from_host)
        sleep @connect_timeout
        raise Socket::ConnectError.new("Connection to #{address} timed out (partition)")
      end
      sleep one_way_delay
      accept = @listeners[address]?
      sleep one_way_delay
      unless accept
        raise Socket::ConnectError.new("Connection refused: #{address}")
      end

      local = "#{from_host}:#{@next_port += 1}"
      link = Link.new(self, local, address)
      @links << link
      @trace.event("connect #{local} -> #{address}")
      spawn(name: "sim-accept #{address}") { accept.call(link.server) }
      link.client
    end

    # Blocks traffic from *from* to *to* (and back unless *one_way*).
    def partition(from : String, to : String, one_way : Bool = false) : Nil
      @blocked << {from, to}
      @blocked << {to, from} unless one_way
      @trace.event("partition #{from} #{one_way ? "->" : "<->"} #{to}")
    end

    def heal(from : String, to : String) : Nil
      @blocked.delete({from, to})
      @blocked.delete({to, from})
      @trace.event("heal #{from} <-> #{to}")
      @heal_signal.broadcast
    end

    def heal_all : Nil
      @blocked.clear
      @trace.event("heal all")
      @heal_signal.broadcast
    end

    def blocked?(from : String, to : String) : Bool
      @blocked.includes?({from, to})
    end

    # Resets every connection involving *host* (both ends see a reset).
    def reset_host(host : String) : Nil
      @links.each do |link|
        link.reset if Network.host(link.client_address) == host || Network.host(link.server_address) == host
      end
      @trace.event("reset #{host}")
    end

    # Open (not fully closed) connections.
    def open_links : Array(Link)
      @links.reject!(&.finished?)
      @links.dup
    end

    protected def wait_for_heal : Nil
      @heal_signal.wait
    end

    protected def one_way_delay : Time::Span
      jitter_ns = @jitter.total_nanoseconds.to_i64
      @latency + Time::Span.new(nanoseconds: jitter_ns > 0 ? Sim.rng.rand(jitter_ns) : 0_i64)
    end

    def self.host(address : String) : String
      address.rpartition(':')[0]
    end
  end

  # A connection: two pipes, one per direction.
  class Link
    getter client : Endpoint
    getter server : Endpoint
    getter client_address : String
    getter server_address : String

    def initialize(network : Network, @client_address : String, @server_address : String)
      up = Pipe.new(network, Network.host(@client_address), Network.host(@server_address))
      down = Pipe.new(network, Network.host(@server_address), Network.host(@client_address))
      @client = Endpoint.new(down, up, @client_address, @server_address)
      @server = Endpoint.new(up, down, @server_address, @client_address)
    end

    def reset : Nil
      @client.reset
      @server.reset
    end

    def finished? : Bool
      @client.finished? && @server.finished?
    end
  end

  # One direction of a connection.
  class Pipe
    getter from : String
    getter to : String

    @in_flight = Deque({Int64, Bytes}).new
    @in_flight_bytes = 0
    @readable = IO::Memory.new
    @read_pos = 0
    @last_delivery_ns = 0_i64
    @fin_sent = false
    @fin_delivered = false
    property? reset = false
    # The receiving end was closed: further writes fail like writes to a
    # socket whose peer closed (EPIPE / RST).
    @reader_closed = false
    @data_signal = Signal.new   # data, FIN or reset delivered
    @space_signal = Signal.new  # window space freed
    @flight_signal = Signal.new # new segment in flight
    @deliverer : Fiber? = nil

    def initialize(@network : Network, @from : String, @to : String)
    end

    # Queues *data* for delivery, blocking while the window is full.
    def write(data : Bytes) : Nil
      offset = 0
      while offset < data.size
        raise IO::Error.new("Connection reset by peer") if @reset || @reader_closed
        while buffered >= @network.window && !@reset && !@reader_closed
          @space_signal.wait
        end
        raise IO::Error.new("Connection reset by peer") if @reset || @reader_closed
        size = Math.min(data.size - offset, 1 + Sim.rng.rand(@network.max_segment))
        enqueue(data[offset, size].dup)
        offset += size
      end
    end

    def close_write : Nil
      return if @fin_sent
      @fin_sent = true
      enqueue(Bytes.empty) # FIN marker
    end

    # Reads delivered data; 0 at FIN. Raises if the connection was reset.
    def read(slice : Bytes) : Int32
      loop do
        raise IO::Error.new("Connection reset by peer") if @reset
        available = @readable.size - @read_pos
        if available > 0
          count = Math.min(available, slice.size)
          slice.copy_from(@readable.to_slice[@read_pos, count])
          @read_pos += count
          if @read_pos == @readable.size
            @readable.clear
            @read_pos = 0
          end
          @space_signal.broadcast
          return count
        end
        return 0 if @fin_delivered
        @data_signal.wait
      end
    end

    def abort : Nil
      return if @reset
      @reset = true
      @in_flight.clear
      @in_flight_bytes = 0
      @data_signal.broadcast
      @space_signal.broadcast
      @flight_signal.broadcast
    end

    def finished? : Bool
      @reset || (@fin_delivered && @readable.size == @read_pos)
    end

    private def buffered : Int32
      @in_flight_bytes + (@readable.size - @read_pos)
    end

    private def enqueue(segment : Bytes) : Nil
      delay = @network.one_way_delay
      if (bandwidth = @network.bandwidth) && !segment.empty?
        delay += Time::Span.new(nanoseconds: segment.size.to_i64 * 1_000_000_000 // bandwidth)
      end
      # Segments arrive in order: never before the previous one.
      deliver_ns = Math.max(Sim.now_ns + delay.total_nanoseconds.to_i64, @last_delivery_ns)
      @last_delivery_ns = deliver_ns
      @in_flight << {deliver_ns, segment}
      @in_flight_bytes += segment.size
      start_deliverer
      @flight_signal.broadcast
    end

    private def start_deliverer : Nil
      return if @deliverer
      @deliverer = spawn(name: "sim-pipe #{@from}->#{@to}") { deliver_loop }
    end

    private def deliver_loop : Nil
      until @reset || @fin_delivered
        if @in_flight.empty?
          @flight_signal.wait
          next
        end
        deliver_ns, segment = @in_flight.first
        if deliver_ns > Sim.now_ns
          sleep Time::Span.new(nanoseconds: deliver_ns - Sim.now_ns)
          next
        end
        if @network.blocked?(@from, @to)
          @network.wait_for_heal
          next
        end
        @in_flight.shift
        @in_flight_bytes -= segment.size
        if segment.empty?
          @fin_delivered = true
        else
          @readable.write(segment)
        end
        @data_signal.broadcast
      end
    end
  end

  # One end of a simulated connection, usable as a buffered socket.
  class Endpoint < IO
    include IO::Buffered

    getter local_address : String
    getter remote_address : String
    @closed = false

    def initialize(@inbound : Pipe, @outbound : Pipe, @local_address : String, @remote_address : String)
    end

    def reset : Nil
      @inbound.abort
      @outbound.abort
    end

    def finished? : Bool
      (@closed || @inbound.reset?) && @inbound.finished?
    end

    def closed? : Bool
      @closed
    end

    def close_write : Nil
      flush
      @outbound.close_write
    end

    private def unbuffered_read(slice : Bytes) : Int32
      raise IO::Error.new("Closed stream") if @closed
      @inbound.read(slice)
    end

    private def unbuffered_write(slice : Bytes) : Nil
      raise IO::Error.new("Closed stream") if @closed
      @outbound.write(slice)
    end

    private def unbuffered_flush : Nil
    end

    private def unbuffered_close : Nil
      return if @closed
      @closed = true
      @outbound.close_write unless @outbound.reset?
      # Unread data on close makes a real TCP stack send RST; here the peer
      # simply sees the FIN after the data already sent.
      @inbound.abort_reader
    end

    private def unbuffered_rewind : Nil
      raise IO::Error.new("Can't rewind a socket")
    end
  end

  class Pipe
    # The reading side was closed locally: wake blocked readers.
    def abort_reader : Nil
      @reader_closed = true
      @fin_delivered = true
      @in_flight.clear
      @in_flight_bytes = 0
      @flight_signal.broadcast
      @readable.clear
      @read_pos = 0
      @data_signal.broadcast
      @space_signal.broadcast
    end
  end

  # An ordered log of simulation events, hashed to check determinism.
  class Trace
    getter hash : UInt64 = 14695981039346656037_u64
    getter events = 0
    property? verbose = false

    def event(message : String) : Nil
      line = "#{Sim.elapsed.total_nanoseconds.to_i64} #{message}"
      line.each_byte do |byte|
        @hash = (@hash ^ byte) &* 1099511628211_u64
      end
      @events += 1
      STDOUT.puts "[#{Sim.elapsed}] #{message}" if @verbose
    end
  end
end
