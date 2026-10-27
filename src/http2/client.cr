require "socket"
require "uri"

module HTTP2
  # An HTTP/2 client. A client maintains a single multiplexed connection to
  # one origin, reconnecting transparently when the connection is closed or
  # the server sends GOAWAY.
  #
  # ```
  # client = HTTP2::Client.new("localhost", 8080)
  # response = client.get("/")
  # response.status    # => 200
  # response.body_text # => "Hello /"
  # ```
  class Client
    # The response to a request. The body is streamed from the connection.
    class Response
      getter status : Int32
      getter headers : HTTP::Headers
      getter stream : Stream

      def initialize(@stream : Stream)
        fields = @stream.headers
        @status = 0
        fields.each do |(name, value)|
          @status = value.to_i if name == ":status"
        end
        @headers = Server.to_headers(fields)
      end

      def body : IO
        @stream.body
      end

      # Reads the remaining body as a string.
      def body_text : String
        body.gets_to_end
      end

      # The trailers, available once the body has been read.
      def trailers : HTTP::Headers?
        @stream.trailers.try { |fields| Server.to_headers(fields) }
      end

      def success? : Bool
        200 <= @status < 300
      end
    end

    getter host : String
    getter port : Int32
    getter? tls : Bool
    getter local_settings : Settings
    getter connection_window_size : Int32
    property connect_timeout : Time::Span? = 10.seconds

    @options : ConnectionOptions

    # Transport behaviour (keepalive, abuse limits) of new connections. When
    # a server closes a connection with GOAWAY(ENHANCE_YOUR_CALM,
    # "too_many_pings"), `keepalive_time` is doubled for later connections
    # (gRPC A8).
    def options : ConnectionOptions
      @mutex.synchronize { @options }
    end

    # :ditto:
    def options=(options : ConnectionOptions) : ConnectionOptions
      @mutex.synchronize { @options = options }
    end

    @tls_context : OpenSSL::SSL::Context::Client? = nil
    @connection : Connection? = nil
    @io_factory : Proc(IO)? = nil
    @socket : Socket? = nil
    @mutex = Mutex.new
    @authority : String

    def self.default_settings : Settings
      Settings.new(
        enable_push: false,
        initial_window_size: 1_048_576_u32,
        max_header_list_size: 1_048_576_u32,
      )
    end

    # Client side defaults: no keepalive pings (enable them with
    # `ConnectionOptions#keepalive_time`).
    def self.default_options : ConnectionOptions
      ConnectionOptions.new
    end

    def initialize(@host : String, @port : Int32, tls : Bool | OpenSSL::SSL::Context::Client = false,
                   @local_settings : Settings = Client.default_settings, @connection_window_size : Int32 = 16_777_216,
                   @options : ConnectionOptions = Client.default_options)
      case tls
      when OpenSSL::SSL::Context::Client
        @tls = true
        @tls_context = tls
      when true
        @tls = true
        @tls_context = OpenSSL::SSL::Context::Client.new
      else
        @tls = false
      end
      @tls_context.try &.alpn_protocol = "h2"
      @authority = default_port? ? @host : "#{@host}:#{@port}"
    end

    # Creates a client that obtains connections from *factory*, e.g. to use
    # a UNIX socket or an in-memory transport.
    def initialize(@authority : String, @local_settings : Settings = Client.default_settings,
                   @connection_window_size : Int32 = 16_777_216, tls : Bool = false,
                   @options : ConnectionOptions = Client.default_options, &factory : -> IO)
      @host = @authority
      @port = 0
      @tls = tls
      @io_factory = factory
    end

    def self.new(uri : URI, tls_context : OpenSSL::SSL::Context::Client? = nil, options : ConnectionOptions = default_options) : Client
      tls = uri.scheme == "https"
      port = uri.port || (tls ? 443 : 80)
      context = tls ? (tls_context || true) : false
      new(uri.host || raise(ArgumentError.new("URI without host")), port, context, options: options)
    end

    def scheme : String
      @tls ? "https" : "http"
    end

    def authority : String
      @authority
    end

    # Returns an open connection, establishing a new one if necessary.
    def connection : Connection
      @mutex.synchronize do
        if (connection = @connection) && connection.available?
          return connection
        end
        io = connect
        connection = Connection.new(io, Connection::Role::Client, @local_settings, @connection_window_size, @options)
        connection.raw_socket = @socket || io.as?(Socket)
        @socket = nil
        connection.on_close { |closed| connection_closed(closed) }
        connection.start
        @connection = connection
      end
    end

    # Opens a stream for a request with the given pseudo-header and header
    # fields. Use this for full control over streaming request and response
    # bodies.
    def open_stream(method : String, path : String, headers : HTTP::Headers? = nil, end_stream : Bool = false) : Stream
      fields = [{":method", method}, {":scheme", scheme}, {":authority", authority}, {":path", path}]
      fields.concat(Server.to_fields(headers)) if headers
      open_stream(fields, end_stream)
    end

    # Opens a stream with raw header *fields*. Requests refused by a server
    # shutting down are retried on a new connection.
    def open_stream(fields : Array({String, String}), end_stream : Bool = false) : Stream
      attempts = 0
      loop do
        begin
          return connection.open_stream(fields, end_stream)
        rescue e : RefusedStreamError | ConnectionClosedError
          attempts += 1
          raise e if attempts >= 3
        end
      end
    end

    # Performs a request and returns once the response headers arrive.
    def request(method : String, path : String, headers : HTTP::Headers? = nil, body : String | Bytes | IO | Nil = nil) : Response
      body = body.to_slice if body.is_a?(String)
      empty = body.nil? || (body.is_a?(Bytes) && body.empty?)
      stream = open_stream(method, path, headers, end_stream: empty)
      begin
        case body
        when Bytes
          stream.send_data(body, end_stream: true) unless body.empty?
        when IO
          buffer = Bytes.new(16_384)
          while (read = body.read(buffer)) > 0
            stream.send_data(buffer[0, read])
          end
          stream.close_send
        end
      rescue e : StreamResetError
        # A server may send a complete response and then stop the request
        # body with RST_STREAM(NO_ERROR); the response must not be discarded
        # (RFC 9113 section 8.1).
        raise e unless e.remote? && e.code.no_error? && stream.end_stream_received?
      end
      Response.new(stream)
    end

    {% for method in %w(get head delete options) %}
      def {{method.id}}(path : String, headers : HTTP::Headers? = nil) : Response
        request({{method.upcase}}, path, headers)
      end
    {% end %}

    {% for method in %w(post put patch) %}
      def {{method.id}}(path : String, headers : HTTP::Headers? = nil, body : String | Bytes | IO | Nil = nil) : Response
        request({{method.upcase}}, path, headers, body)
      end
    {% end %}

    # Sends a PING on the current connection and returns the round trip time.
    def ping(timeout : Time::Span = 10.seconds) : Time::Span
      connection.ping(timeout)
    end

    # Closes the underlying connection.
    def close : Nil
      connection = @mutex.synchronize do
        conn = @connection
        @connection = nil
        conn
      end
      if connection
        connection.shutdown(1.second)
        connection.wait_closed
      end
    end

    # Backs off keepalive when the server complained about too many pings.
    private def connection_closed(connection : Connection) : Nil
      goaway = connection.goaway_received
      return unless goaway && goaway.error_code.enhance_your_calm? && String.new(goaway.debug_data) == "too_many_pings"
      @mutex.synchronize do
        if time = @options.keepalive_time
          @options.keepalive_time = time * 2
        end
      end
    end

    private def connect : IO
      if factory = @io_factory
        return factory.call
      end
      socket = TCPSocket.new(@host, @port, connect_timeout: @connect_timeout)
      socket.tcp_nodelay = true
      @socket = socket
      if context = @tls_context
        ssl = OpenSSL::SSL::Socket::Client.new(socket, context, sync_close: true, hostname: @host)
        unless ssl.alpn_protocol == "h2"
          ssl.close
          raise ConnectionClosedError.new("Server did not negotiate h2 via ALPN", ErrorCode::HTTP_1_1_REQUIRED)
        end
        ssl
      else
        socket
      end
    end

    private def default_port? : Bool
      (@tls && @port == 443) || (!@tls && @port == 80)
    end
  end
end
