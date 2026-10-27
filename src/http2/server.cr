require "socket"
require "log"

module HTTP2
  # An HTTP/2 server.
  #
  # ```
  # server = HTTP2::Server.new do |context|
  #   context.response.headers["content-type"] = "text/plain"
  #   context.response.print "Hello #{context.request.path}"
  # end
  # server.bind_tcp("127.0.0.1", 8080)
  # server.listen
  # ```
  #
  # Cleartext connections use HTTP/2 with prior knowledge (as used by gRPC).
  # TLS connections negotiate `h2` using ALPN. Setting `#http1_handler`
  # additionally serves HTTP/1.1 (including the h2c upgrade) on the same
  # listeners:
  #
  # ```
  # server.http1_handler = HTTP::Handler::HandlerProc.new do |context|
  #   context.response.print "Hello over HTTP/1.1"
  # end
  # ```
  class Server
    Log = ::Log.for("http2.server")

    # A request received by the server.
    class Request
      getter method : String
      getter path : String
      getter scheme : String
      getter authority : String?
      getter headers : HTTP::Headers
      getter stream : Stream

      def initialize(@stream : Stream, fields : Array({String, String}))
        method = path = scheme = authority = nil
        @headers = HTTP::Headers.new
        fields.each do |(name, value)|
          case name
          when ":method"    then method = value
          when ":path"      then path = value
          when ":scheme"    then scheme = value
          when ":authority" then authority = value
          when .starts_with?(':')
          else
            @headers.add(name, value)
          end
        end
        @method = method || ""
        @path = path || ""
        @scheme = scheme || ""
        @authority = authority || @headers["host"]?
      end

      # The request body.
      def body : IO
        @stream.body
      end

      # The request trailers, available once the body has been read.
      def trailers : HTTP::Headers?
        @stream.trailers.try { |fields| Server.to_headers(fields) }
      end

      # The path without the query string.
      def resource_path : String
        @path.split('?', 2)[0]
      end
    end

    # The response to a request. Writing to the response sends the headers
    # (if not sent already) followed by DATA frames. Output is buffered;
    # use `#flush` to send buffered data immediately.
    class Response < IO
      BUFFER_SIZE = 16_384

      property status : Int32 = 200
      getter headers = HTTP::Headers.new
      # Trailers sent after the body when the response is closed.
      getter trailers = HTTP::Headers.new
      getter stream : Stream
      getter? closed = false

      @buffer = IO::Memory.new
      @headers_sent = false

      def initialize(@stream : Stream)
      end

      def status=(status : HTTP::Status) : HTTP::Status
        @status = status.code
        status
      end

      def headers_sent? : Bool
        @headers_sent
      end

      def read(slice : Bytes) : NoReturn
        raise IO::Error.new("Response is write-only")
      end

      def write(slice : Bytes) : Nil
        raise IO::Error.new("Closed response") if @closed
        return if slice.empty?
        @buffer.write(slice)
        flush_buffer if @buffer.size >= BUFFER_SIZE
      end

      # Sends the response headers without any body data.
      def send_headers : Nil
        return if @headers_sent
        @headers_sent = true
        @stream.send_headers(header_fields)
      end

      def flush : Nil
        raise IO::Error.new("Closed response") if @closed
        send_headers
        flush_buffer
      end

      # Completes the response: sends any buffered data, followed by trailers
      # if present, and closes the stream for sending.
      def close : Nil
        return if @closed
        @closed = true
        return if @stream.end_stream_sent? || @stream.reset?

        if @trailers.empty?
          if !@headers_sent && @buffer.empty?
            @headers_sent = true
            @stream.send_headers(header_fields, end_stream: true)
          else
            send_headers
            @stream.send_data(take_buffer, end_stream: true)
          end
        else
          send_headers
          flush_buffer
          @stream.send_trailers(Server.to_fields(@trailers))
        end
      end

      private def flush_buffer : Nil
        return if @buffer.empty?
        send_headers
        @stream.send_data(take_buffer)
      end

      private def take_buffer : Bytes
        data = @buffer.to_slice.dup
        @buffer.clear
        data
      end

      private def header_fields : Array({String, String})
        fields = [{":status", @status.to_s}]
        fields.concat(Server.to_fields(@headers))
        fields
      end
    end

    # The context handed to a handler for each request.
    class Context
      getter request : Request
      getter response : Response

      def initialize(@request : Request, @response : Response)
      end

      def stream : Stream
        @request.stream
      end
    end

    # A request handler.
    module Handler
      abstract def call(context : Context)
    end

    getter local_settings : Settings
    getter connection_window_size : Int32
    getter? listening = false

    # Transport behaviour (keepalive, connection lifetime, abuse limits) of
    # the connections accepted from now on.
    property options : ConnectionOptions

    # Serves HTTP/1.1 connections when set. Connections that do not start
    # with the HTTP/2 connection preface (or TLS connections that negotiated
    # `http/1.1` via ALPN; `h2,http/1.1` is advertised when this is set) are
    # handed to Crystal's HTTP/1.1 server machinery (keep-alive, chunked
    # encoding, streaming request and response bodies) and this handler.
    # Without a handler, only HTTP/2 is served.
    property http1_handler : HTTP::Handler | HTTP::Handler::HandlerProc | Nil = nil

    # Accept cleartext HTTP/1.1 requests carrying `Upgrade: h2c` (RFC 7540
    # section 3.2) when `http1_handler` is set: the server answers
    # `101 Switching Protocols` and serves the request as stream 1 with the
    # HTTP/2 handler.
    property? h2c_upgrade : Bool = true

    # Upper bound on the time a new connection may take to complete the TLS
    # handshake and send its first bytes. `nil` disables the timeout.
    property handshake_timeout : Time::Span? = 10.seconds

    # Read timeout applied to HTTP/1.1 connections (also bounds the idle
    # time between keep-alive requests). `nil` disables the timeout.
    property http1_read_timeout : Time::Span? = 60.seconds

    # Largest request body accepted with an h2c upgrade request; larger
    # requests are served over HTTP/1.1 instead.
    property h2c_max_body_size : Int32 = 65_536

    @handler : Handler | Proc(Context, Nil)
    @servers = [] of {Socket::Server, OpenSSL::SSL::Context::Server?}
    @connections = Set(Connection).new
    @http1_sessions = Set(HTTP1Session).new
    @mutex = Mutex.new
    @closed = Atomic(Bool).new(false)

    def self.default_settings : Settings
      Settings.new(
        max_concurrent_streams: 100_u32,
        initial_window_size: 1_048_576_u32,
        max_header_list_size: 1_048_576_u32,
      )
    end

    # Server side defaults: keepalive pings after two hours of inactivity
    # and gRPC's keepalive enforcement policy (PINGs at most every five
    # minutes while streams are active).
    def self.default_options : ConnectionOptions
      ConnectionOptions.new(
        keepalive_time: 2.hours,
        keepalive_timeout: 20.seconds,
        min_ping_interval: 5.minutes,
        permit_without_stream: false,
      )
    end

    def initialize(@handler : Handler | Proc(Context, Nil), @local_settings : Settings = Server.default_settings,
                   @connection_window_size : Int32 = 16_777_216, @options : ConnectionOptions = Server.default_options)
    end

    def self.new(local_settings : Settings = default_settings, connection_window_size : Int32 = 16_777_216,
                 options : ConnectionOptions = default_options, &block : Context ->)
      new(block, local_settings, connection_window_size, options)
    end

    # The open HTTP/2 connections.
    def connections : Array(Connection)
      @mutex.synchronize { @connections.to_a }
    end

    # The addresses of the bound listeners.
    def listen_addresses : Array(Socket::Address)
      listeners.map(&.[1])
    end

    # The bound listeners with their identifiers (shared with connection
    # ids, used by channelz).
    def listeners : Array({Int64, Socket::Address})
      @servers.each_with_index.compact_map do |(server, _), index|
        address = begin
          server.as?(TCPServer).try(&.local_address) || server.as?(UNIXServer).try(&.local_address)
        rescue Socket::Error
          nil
        end
        address.try { |a| {listener_id(index), a.as(Socket::Address)} }
      end.to_a
    end

    @listener_ids = [] of Int64

    private def listener_id(index : Int32) : Int64
      @mutex.synchronize do
        while @listener_ids.size <= index
          @listener_ids << ConnectionMetrics.next_id
        end
        @listener_ids[index]
      end
    end

    # Binds a cleartext TCP listener. Returns the bound address.
    def bind_tcp(host : String, port : Int32, reuse_port : Bool = false) : Socket::IPAddress
      server = TCPServer.new(host, port, reuse_port: reuse_port)
      @servers << {server, nil}
      server.local_address
    end

    def bind_tcp(port : Int32) : Socket::IPAddress
      bind_tcp("127.0.0.1", port)
    end

    # Binds a TLS listener. `h2` (and `http/1.1` if `http1_handler` is set
    # when `#listen` is called) is negotiated using ALPN.
    def bind_tls(host : String, port : Int32, context : OpenSSL::SSL::Context::Server, reuse_port : Bool = false) : Socket::IPAddress
      context.alpn_protocol = "h2"
      server = TCPServer.new(host, port, reuse_port: reuse_port)
      @servers << {server, context}
      server.local_address
    end

    # Binds a UNIX socket listener.
    def bind_unix(path : String) : Socket::UNIXAddress
      server = UNIXServer.new(path)
      @servers << {server, nil}
      server.local_address
    end

    # Starts accepting connections on all bound sockets. Blocks until the
    # server is closed.
    def listen : Nil
      raise "No bound sockets" if @servers.empty?
      @listening = true
      done = Channel(Nil).new
      @servers.each do |(server, tls)|
        tls.alpn_protocols = alpn_protocols if tls
        spawn(name: "http2-accept") do
          accept_loop(server, tls)
        ensure
          done.send(nil)
        end
      end
      @servers.size.times { done.receive }
    ensure
      @listening = false
    end

    # The ALPN protocols advertised on TLS listeners.
    def alpn_protocols : Array(String)
      @http1_handler ? ["h2", "http/1.1"] : ["h2"]
    end

    # Serves a single connection over *io* in the current fiber. Useful for
    # custom transports and tests. When `http1_handler` is set, HTTP/1.1
    # connections are detected and served as well.
    def handle_connection(io : IO, remote_address : String? = nil) : Nil
      if @http1_handler
        serve_detected(io, io.as?(Socket), remote_address, tls: false)
      else
        serve_http2(io, io.as?(Socket), remote_address)
      end
    end

    # Stops accepting connections and gracefully shuts down all open
    # connections, waiting up to *timeout* for active streams.
    def close(timeout : Time::Span = 5.seconds) : Nil
      connections, sessions = @mutex.synchronize do
        @closed.set(true)
        {@connections.to_a, @http1_sessions.to_a}
      end
      @servers.each { |(server, _)| server.close rescue nil }
      done = Channel(Nil).new
      connections.each do |connection|
        spawn(name: "http2-shutdown") do
          connection.shutdown(timeout)
        ensure
          done.send(nil)
        end
      end
      sessions.each do |session|
        spawn(name: "http1-shutdown") do
          session.shutdown(timeout)
        ensure
          done.send(nil)
        end
      end
      (connections.size + sessions.size).times { done.receive }
    end

    def closed? : Bool
      @closed.get
    end

    private def accept_loop(server : Socket::Server, tls : OpenSSL::SSL::Context::Server?) : Nil
      while client = server.accept?
        spawn_client(client.as(Socket), tls)
      end
    rescue e : IO::Error
      Log.debug(exception: e) { "Accept loop terminated" } unless closed?
    end

    # A separate method so that each fiber captures its own socket (a block
    # in the accept loop would share the loop variable).
    private def spawn_client(socket : Socket, tls : OpenSSL::SSL::Context::Server?) : Nil
      spawn(name: "http2-client") { handle_client(socket, tls) }
    end

    private def handle_client(socket : Socket, tls : OpenSSL::SSL::Context::Server?) : Nil
      if socket.is_a?(TCPSocket)
        socket.tcp_nodelay = true
      end
      remote_address = begin
        socket.as?(IPSocket).try(&.remote_address.to_s)
      rescue Socket::Error
        nil
      end
      unless tls
        handle_connection(socket, remote_address)
        return
      end

      socket.read_timeout = @handshake_timeout
      ssl = OpenSSL::SSL::Socket::Server.new(socket, tls, sync_close: true)
      case ssl.alpn_protocol
      when "h2"
        socket.read_timeout = nil
        serve_http2(ssl, socket, remote_address)
      when "http/1.1"
        if @http1_handler
          serve_http1(ssl, socket, tls: true)
        else
          Log.debug { "Client negotiated http/1.1 but no HTTP/1.1 handler is configured" }
          ssl.close
        end
      else
        if @http1_handler
          serve_detected(ssl, socket, remote_address, tls: true)
        else
          Log.debug { "Client did not negotiate h2 via ALPN" }
          ssl.close
        end
      end
    rescue e : IO::Error | OpenSSL::SSL::Error
      Log.debug(exception: e) { "Connection error" }
      socket.close rescue nil
    end

    # Reads the first bytes of a connection to tell HTTP/2 (connection
    # preface) from HTTP/1.1 and serves it accordingly.
    private def serve_detected(io : IO, socket : Socket?, remote_address : String?, tls : Bool) : Nil
      preface = Connection::CLIENT_PREFACE
      buffer = Bytes.new(preface.size)
      count = 0
      matches = true
      begin
        socket.try &.read_timeout = @handshake_timeout
        while matches && count < buffer.size
          read = io.read(buffer + count)
          break if read == 0
          matches = buffer[count, read] == preface[count, read]
          count += read
        end
      ensure
        socket.try &.read_timeout = nil
      end

      if count == 0
        io.close rescue nil
      elsif matches && count == preface.size
        serve_http2(io, socket, remote_address, preface_received: true)
      else
        ip = socket.as?(IPSocket)
        prefixed = PrefixedIO.new(buffer[0, count], io,
          (ip.try(&.remote_address) rescue nil), (ip.try(&.local_address) rescue nil))
        serve_http1(prefixed, socket, tls)
      end
    end

    private def serve_http2(io : IO, socket : Socket?, remote_address : String?, preface_received : Bool = false,
                            upgrade : H2C::Upgrade? = nil, body : Bytes = Bytes.empty) : Nil
      connection = Connection.new(io, Connection::Role::Server, @local_settings, @connection_window_size, @options)
      connection.remote_address = remote_address
      connection.local_address = begin
        socket.as?(IPSocket).try(&.local_address.to_s)
      rescue Socket::Error
        nil
      end
      connection.raw_socket = socket
      connection.preface_received! if preface_received
      connection.on_stream = ->(stream : Stream) { handle_stream(stream) }
      @mutex.synchronize do
        if closed?
          io.close rescue nil
          return
        end
        @connections << connection
      end
      begin
        connection.accept_upgrade(upgrade.fields, upgrade.settings, body) if upgrade
        connection.run
      ensure
        @mutex.synchronize { @connections.delete(connection) }
      end
    end

    # Serves an HTTP/1.1 connection with `http1_handler`, upgrading to
    # HTTP/2 when the client asks for h2c.
    private def serve_http1(io : IO, socket : Socket?, tls : Bool) : Nil
      handler = @http1_handler.not_nil!
      if buffered = (io.as?(PrefixedIO).try(&.io) || io).as?(IO::Buffered)
        buffered.sync = false
      end
      socket.try &.read_timeout = @http1_read_timeout
      session = uninitialized HTTP1Session
      processor = HTTP::Server::RequestProcessor.new do |context|
        if !tls && @h2c_upgrade && (upgrade = H2C.parse(context.request)) && (body = read_upgrade_body(context.request))
          accept_h2c(context, upgrade, body, socket, session)
        else
          session.busy { handler.call(context) }
        end
      end
      session = HTTP1Session.new(processor, io, socket)
      @mutex.synchronize do
        if closed?
          io.close rescue nil
          return
        end
        @http1_sessions << session
      end
      begin
        processor.process(io, io)
      ensure
        @mutex.synchronize { @http1_sessions.delete(session) }
        io.close rescue nil
      end
    end

    # Reads the body of an h2c upgrade request, which is delivered on
    # stream 1. Returns `nil` (no upgrade) if it is too large or chunked.
    private def read_upgrade_body(request : HTTP::Request) : Bytes?
      body = request.body
      return Bytes.empty unless body
      length = request.content_length
      return nil unless length && length <= @h2c_max_body_size
      bytes = Bytes.new(length)
      body.read_fully(bytes)
      bytes
    end

    private def accept_h2c(context : HTTP::Server::Context, upgrade : H2C::Upgrade, body : Bytes,
                           socket : Socket?, session : HTTP1Session) : Nil
      response = context.response
      response.status = HTTP::Status::SWITCHING_PROTOCOLS
      response.headers["Connection"] = "Upgrade"
      response.headers["Upgrade"] = "h2c"
      remote_address = context.request.remote_address.try(&.to_s)
      session.upgraded!
      response.upgrade do |io|
        socket.try &.read_timeout = nil
        serve_http2(io, socket, remote_address, upgrade: upgrade, body: body)
      end
    end

    private def handle_stream(stream : Stream) : Nil
      request = Request.new(stream, stream.headers)
      response = Response.new(stream)
      context = Context.new(request, response)
      begin
        handler = @handler
        handler.is_a?(Handler) ? handler.call(context) : handler.call(context)
        response.close
      rescue e : StreamResetError | ConnectionClosedError
        Log.debug(exception: e) { "Stream #{stream.id} terminated" }
        return
      rescue e
        Log.error(exception: e) { "Unhandled exception while handling stream #{stream.id}" }
        if response.headers_sent?
          stream.reset(ErrorCode::INTERNAL_ERROR)
        else
          response.headers.clear
          response.trailers.clear
          response.status = 500
          response.close rescue nil
        end
      end
      # The response is complete; if the client is still sending, ask it to
      # stop without error (RFC 9113 section 8.1).
      stream.reset(ErrorCode::NO_ERROR) unless stream.end_stream_received? || stream.closed?
    rescue e : Error
      Log.debug(exception: e) { "Stream #{stream.id} terminated" }
    end

    # Converts `HTTP::Headers` to HTTP/2 header fields (lowercase names).
    def self.to_fields(headers : HTTP::Headers) : Array({String, String})
      fields = [] of {String, String}
      headers.each do |name, values|
        lower = name.downcase
        next if HeaderValidation::CONNECTION_HEADERS.includes?(lower)
        values.each { |value| fields << {lower, value} }
      end
      fields
    end

    # Converts HTTP/2 header fields to `HTTP::Headers`, dropping
    # pseudo-header fields.
    def self.to_headers(fields : Array({String, String})) : HTTP::Headers
      headers = HTTP::Headers.new
      fields.each do |(name, value)|
        headers.add(name, value) unless name.starts_with?(':')
      end
      headers
    end

    # :nodoc:
    # Tracks an HTTP/1.1 connection so that `Server#close` can stop it.
    class HTTP1Session
      @busy = false
      @upgraded = false
      @mutex = Mutex.new
      @done = Channel(Nil).new

      def initialize(@processor : HTTP::Server::RequestProcessor, @io : IO, @socket : Socket?)
      end

      # Runs a request handler, marking the connection busy.
      def busy(&) : Nil
        @mutex.synchronize { @busy = true }
        begin
          yield
        ensure
          @mutex.synchronize { @busy = false }
        end
      end

      # The connection was upgraded to HTTP/2 and is tracked as such.
      def upgraded! : Nil
        @mutex.synchronize { @upgraded = true }
      end

      # Stops serving further requests; idle connections are closed at
      # once, busy ones after the current request or *timeout*.
      def shutdown(timeout : Time::Span) : Nil
        @processor.close
        deadline = Time.instant + timeout
        loop do
          busy, upgraded = @mutex.synchronize { {@busy, @upgraded} }
          return if upgraded
          if !busy || Time.instant >= deadline
            abort
            return
          end
          sleep 10.milliseconds
        end
      end

      private def abort : Nil
        if socket = @socket
          socket.close_read rescue nil
          socket.close_write rescue nil if @mutex.synchronize { @busy }
        else
          @io.close rescue nil
        end
      end
    end
  end
end
