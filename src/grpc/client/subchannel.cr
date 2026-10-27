module GRPC
  # :nodoc:
  #
  # Everything a subchannel needs to establish connections: transport
  # security, HTTP/2 settings, backoff and keepalive. Shared by all
  # subchannels of a channel; also tracks their open connections so that
  # `Channel#close` can wait for them.
  class TransportOptions
    getter credentials : ChannelCredentials
    getter authority : String
    getter settings : HTTP2::Settings
    getter connection_window_size : Int32
    getter backoff : ConnectionBackoff
    getter keepalive : KeepaliveOptions?
    getter io_factory : Proc(IO)?
    getter dialer : Proc(Resolver::Address, Time::Instant, IO)?

    @connections = Set(HTTP2::Connection).new
    @mutex = Mutex.new

    def initialize(@credentials : ChannelCredentials, @authority : String, @settings : HTTP2::Settings,
                   @connection_window_size : Int32, @backoff : ConnectionBackoff,
                   @keepalive : KeepaliveOptions? = nil, @io_factory : Proc(IO)? = nil,
                   @dialer : Proc(Resolver::Address, Time::Instant, IO)? = nil)
    end

    # The host name used for TLS SNI and certificate verification.
    def server_name : String
      @credentials.server_name_override || Resolver.split_host_port(@authority)[0]
    rescue ArgumentError
      @authority
    end

    # Opens a transport to *address*, giving up at *deadline*.
    def connect(address : Resolver::Address, deadline : Time::Instant) : IO
      if factory = @io_factory
        return factory.call
      end
      socket = if dialer = @dialer
                 dialer.call(address, deadline)
               else
                 dial(address, deadline)
               end
      context = @credentials.tls_context
      return socket unless context
      begin
        if socket.is_a?(Socket)
          socket.read_timeout = remaining(deadline)
          socket.write_timeout = remaining(deadline)
        end
        ssl = OpenSSL::SSL::Socket::Client.new(socket, context, sync_close: true, hostname: server_name)
        if socket.is_a?(Socket)
          socket.read_timeout = nil
          socket.write_timeout = nil
        end
        unless ssl.alpn_protocol == "h2"
          ssl.close rescue nil
          raise Socket::Error.new("Server did not negotiate h2 via ALPN")
        end
        ssl
      rescue e
        socket.close rescue nil
        raise e
      end
    end

    private def dial(address : Resolver::Address, deadline : Time::Instant) : IO
      case address.kind
      in .tcp?
        tcp = TCPSocket.new(address.host, address.port, connect_timeout: remaining(deadline))
        tcp.tcp_nodelay = true
        tcp
      in .unix?
        UNIXSocket.new(address.path)
      in .unix_abstract?
        raise Socket::Error.new("Abstract UNIX sockets are not supported by this runtime")
      in .custom?
        raise Socket::Error.new("Address #{address} requires a custom dialer")
      end
    end

    protected def track(connection : HTTP2::Connection) : Nil
      @mutex.synchronize { @connections << connection }
    end

    protected def untrack(connection : HTTP2::Connection) : Nil
      @mutex.synchronize { @connections.delete(connection) }
    end

    # Gracefully closes all connections, waiting up to *grace* for calls
    # in flight.
    def close_all(grace : Time::Span) : Nil
      connections = @mutex.synchronize { @connections.to_a }
      done = ::Channel(Nil).new(connections.size)
      connections.each do |connection|
        spawn(name: "grpc-close-connection") do
          begin
            connection.shutdown(grace)
            connection.wait_closed
          rescue
          end
          done.send(nil)
        end
      end
      connections.size.times { done.receive }
    end

    private def remaining(deadline : Time::Instant) : Time::Span
      Math.max(deadline - Time.instant, 1.millisecond)
    end
  end

  # A connection to one address, owned by a load balancing policy. A
  # subchannel starts IDLE, connects when asked (`#request_connection`),
  # becomes READY once the server's HTTP/2 preface was received, and goes
  # back to IDLE when the connection is lost or the server sends GOAWAY.
  # Failed attempts move it to TRANSIENT_FAILURE until the backoff delay
  # (https://github.com/grpc/grpc/blob/master/doc/connection-backoff.md)
  # elapsed, then to IDLE.
  #
  # State changes are delivered to the callbacks registered with `#watch`,
  # in order, serially with the policy's other callbacks.
  class Subchannel
    alias Watcher = Proc(ConnectivityState, String?, Nil)

    getter address : Resolver::Address
    # Identifier of the subchannel in channelz.
    getter channelz_id : Int64 = ChannelzRegistry.next_id
    # When the subchannel was created.
    getter created_at : Time = Time.utc

    # The current connection, if any.
    def connection : HTTP2::Connection?
      @mutex.synchronize { @connection }
    end

    @state = ConnectivityState::Idle
    @connection : HTTP2::Connection? = nil
    @last_error : String? = nil
    @watchers = [] of Watcher
    @mutex = Mutex.new
    @stop = ::Channel(Nil).new
    @backoff : Backoff

    def initialize(@address : Resolver::Address, @options : TransportOptions, @serializer : WorkSerializer)
      @backoff = Backoff.new(@options.backoff)
    end

    def state : ConnectivityState
      @mutex.synchronize { @state }
    end

    # The error of the last failed connection attempt.
    def last_error : String?
      @mutex.synchronize { @last_error }
    end

    # Registers a state change callback (called serially, see `LoadBalancer`).
    def watch(&block : ConnectivityState, String? ->) : Nil
      @mutex.synchronize { @watchers << block }
    end

    # Starts connecting if IDLE.
    def request_connection : Nil
      drain = @mutex.synchronize do
        return unless @state.idle?
        transition_locked(ConnectivityState::Connecting, nil)
      end
      @serializer.drain if drain
      spawn(name: "grpc-subchannel-connect") { connect }
    end

    # Forgets the connection backoff: the next attempt starts immediately
    # and a subchannel waiting in TRANSIENT_FAILURE becomes IDLE.
    def reset_backoff : Nil
      drain = @mutex.synchronize do
        @backoff.reset
        @state.transient_failure? ? transition_locked(ConnectivityState::Idle, @last_error) : false
      end
      @serializer.drain if drain
    end

    # The connection for a new call, if READY. Detects connections that
    # received GOAWAY: they are left to drain and the subchannel goes IDLE.
    def ready_connection : HTTP2::Connection?
      connection = @mutex.synchronize { @connection if @state.ready? }
      return unless connection
      return connection if connection.available?
      connection_lost(connection, "Server sent GOAWAY")
      nil
    end

    # Closes the subchannel. Calls in flight on its connection may finish
    # (bounded by a grace period).
    def shutdown : Nil
      connection = nil
      drain = @mutex.synchronize do
        return if @state.shutdown?
        connection = @connection
        @connection = nil
        @stop.close
        transition_locked(ConnectivityState::Shutdown, nil)
      end
      @serializer.drain if drain
      drain_connection(connection) if connection
    end

    private def drain_connection(connection : HTTP2::Connection) : Nil
      spawn(name: "grpc-subchannel-shutdown") { connection.shutdown(5.seconds) rescue nil }
    end

    def to_s(io : IO) : Nil
      io << "Subchannel(" << @address << ')'
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end

    # Configures a new connection before it starts: client keepalive and
    # prompt reaction to GOAWAY.
    protected def configure_connection(connection : HTTP2::Connection) : Nil
      if keepalive = @options.keepalive
        connection.configure_keepalive(keepalive.time, keepalive.timeout, keepalive.permit_without_calls?)
      end
      # A server that is shutting down (or limiting connection age) sends
      # GOAWAY: stop picking this connection right away so new calls use a
      # fresh one while existing calls drain.
      connection.on_goaway { |_| connection_lost(connection, "Server sent GOAWAY") }
    end

    private def connect : Nil
      delay = @mutex.synchronize { @backoff.next_delay }
      started = Time.instant
      deadline = started + Math.max(delay, @options.backoff.min_connect_timeout)
      connection = begin
        establish(deadline)
      rescue e
        failed(e, started + delay)
        return
      end

      ready = @mutex.synchronize do
        if @state.connecting?
          @connection = connection
          @backoff.reset
          transition_locked(ConnectivityState::Ready, nil)
          true
        else
          false
        end
      end
      case ready
      when true  then @serializer.drain
      when false then connection.close
      end
    end

    # Opens the transport and waits for the server's HTTP/2 preface, which
    # proves an HTTP/2 server is on the other end.
    private def establish(deadline : Time::Instant) : HTTP2::Connection
      io = @options.connect(@address, deadline)
      connection = HTTP2::Connection.new(io, HTTP2::Connection::Role::Client, @options.settings, @options.connection_window_size)
      connection.remote_address = @address.to_s
      connection.local_address = begin
        io.as?(IPSocket).try(&.local_address.to_s)
      rescue Socket::Error
        nil
      end
      configure_connection(connection)
      connection.on_close do |closed|
        @options.untrack(closed)
        connection_lost(closed, closed.close_error.try(&.message) || "Connection closed")
      end
      @options.track(connection)
      connection.start
      # READY once the server's SETTINGS (its HTTP/2 preface) arrived.
      unless connection.wait_for_remote_settings(Math.max(deadline - Time.instant, 1.millisecond))
        error = connection.close_error
        connection.close
        raise error || HTTP2::ConnectionClosedError.new("Timed out waiting for the server's HTTP/2 preface")
      end
      connection
    end

    private def failed(error : Exception, retry_at : Time::Instant) : Nil
      message = "#{@address}: #{error.message || error.class.name}"
      drain = @mutex.synchronize do
        return unless @state.connecting?
        @last_error = message
        transition_locked(ConnectivityState::TransientFailure, message)
      end
      @serializer.drain if drain

      # Leave TRANSIENT_FAILURE once the backoff delay elapsed (or it was
      # reset).
      select
      when @stop.receive?
        return
      when timeout(Math.max(retry_at - Time.instant, Time::Span.zero))
      end
      drain = @mutex.synchronize do
        return unless @state.transient_failure?
        transition_locked(ConnectivityState::Idle, message)
      end
      @serializer.drain if drain
    end

    private def connection_lost(connection : HTTP2::Connection, reason : String) : Nil
      drain = @mutex.synchronize do
        return unless @state.ready? && @connection.same?(connection)
        @connection = nil
        transition_locked(ConnectivityState::Idle, reason)
      end
      @serializer.drain if drain
    end

    # Records a state change and queues the notifications (with the lock
    # held, so they are delivered in order). Returns whether the caller must
    # drain the serializer.
    private def transition_locked(state : ConnectivityState, error : String?) : Bool
      @state = state
      watchers = @watchers.dup
      @serializer.enqueue { watchers.each &.call(state, error) }
    end
  end
end
