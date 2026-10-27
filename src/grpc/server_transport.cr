module GRPC
  # Raised by a `ServerTransport` when the underlying stream was reset or the
  # connection was lost.
  class TransportError < Exception
  end

  # The HTTP exchange carrying one server-side call. `ServerCall` implements
  # the gRPC protocol (framing, headers, trailers, gRPC-Web encoding) on top
  # of it, so the same call machinery serves HTTP/2 and HTTP/1.1.
  abstract class ServerTransport
    # The request body.
    abstract def request_body : IO

    # Sends response headers (including `:status`), optionally ending the
    # response.
    abstract def send_headers(fields : Array({String, String}), end_stream : Bool = false) : Nil

    # Sends response body data, optionally ending the response.
    abstract def send_data(data : Bytes, end_stream : Bool = false) : Nil

    # Sends HTTP trailers, ending the response. Only available when
    # `#supports_trailers?`.
    abstract def send_trailers(fields : Array({String, String})) : Nil

    # Whether HTTP trailers can be sent (required for standard gRPC).
    abstract def supports_trailers? : Bool

    # Aborts the exchange (the client sees the call cancelled).
    abstract def abort : Nil

    # After the response is complete, tells the client to stop sending a
    # request it has not finished.
    abstract def stop_receiving : Nil

    # Whether the exchange is completely closed.
    abstract def closed? : Bool

    # Registers a block called if the client aborts the exchange (stream
    # reset, connection lost) before it completed normally.
    abstract def on_abort(&block : -> Nil) : Nil

    # The address of the client, if known.
    abstract def peer : String?
  end

  # A `ServerTransport` over an HTTP/2 stream.
  class HTTP2ServerTransport < ServerTransport
    getter stream : HTTP2::Stream

    def initialize(@stream : HTTP2::Stream)
      @body = BodyIO.new(@stream)
    end

    def request_body : IO
      @body
    end

    def send_headers(fields : Array({String, String}), end_stream : Bool = false) : Nil
      wrap { @stream.send_headers(fields, end_stream) }
    end

    def send_data(data : Bytes, end_stream : Bool = false) : Nil
      wrap { @stream.send_data(data, end_stream) }
    end

    def send_trailers(fields : Array({String, String})) : Nil
      wrap { @stream.send_trailers(fields) }
    end

    def supports_trailers? : Bool
      true
    end

    def abort : Nil
      @stream.reset(HTTP2::ErrorCode::CANCEL) unless @stream.closed?
    end

    def stop_receiving : Nil
      @stream.reset(HTTP2::ErrorCode::NO_ERROR) unless @stream.closed?
    end

    def closed? : Bool
      @stream.closed?
    end

    def on_abort(&block : -> Nil) : Nil
      @stream.on_close do |stream|
        block.call if stream.error
      end
    end

    def peer : String?
      @stream.connection.remote_address
    end

    private def wrap(&)
      yield
    rescue e : HTTP2::Error
      raise TransportError.new(e.message, cause: e)
    end

    # Converts stream errors into `TransportError`s.
    private class BodyIO < IO
      def initialize(@stream : HTTP2::Stream)
      end

      def read(slice : Bytes) : Int32
        @stream.read(slice)
      rescue e : HTTP2::Error
        raise TransportError.new(e.message, cause: e)
      end

      def write(slice : Bytes) : NoReturn
        raise IO::Error.new("Request body is read-only")
      end
    end
  end

  # Decodes a base64 stream made of independently padded segments, as
  # used by gRPC-Web-text (`application/grpc-web-text`).
  # :nodoc:
  class Base64StreamDecoder < IO
    @quantum = Bytes.new(4)
    @quantum_size = 0
    @decoded = IO::Memory.new
    @eof = false

    def initialize(@io : IO)
    end

    def read(slice : Bytes) : Int32
      while @decoded.pos == @decoded.size && !@eof
        fill
      end
      @decoded.read(slice)
    end

    def write(slice : Bytes) : NoReturn
      raise IO::Error.new("Base64StreamDecoder is read-only")
    end

    private def fill : Nil
      @decoded.clear
      buffer = Bytes.new(4096)
      read = @io.read(buffer)
      if read == 0
        @eof = true
        raise GRPC::Error.new(StatusCode::Internal, "Truncated base64 request body") if @quantum_size != 0
        return
      end
      buffer[0, read].each do |byte|
        next if byte == '\r'.ord || byte == '\n'.ord || byte == ' '.ord
        @quantum[@quantum_size] = byte
        @quantum_size += 1
        if @quantum_size == 4
          begin
            @decoded.write(Base64.decode(String.new(@quantum)))
          rescue Base64::Error
            raise GRPC::Error.new(StatusCode::Internal, "Invalid base64 request body")
          end
          @quantum_size = 0
        end
      end
      @decoded.rewind
    end
  end
end

module GRPC
  # A `ServerTransport` over an HTTP/1.1 exchange (used for gRPC-Web from
  # browsers). HTTP/1.1 cannot carry trailers, so only the gRPC-Web
  # protocols are served this way.
  class HTTP1ServerTransport < ServerTransport
    getter context : HTTP::Server::Context
    @closed = false
    @headers_sent = false

    def initialize(@context : HTTP::Server::Context)
    end

    def request_body : IO
      @context.request.body || IO::Memory.new
    end

    def send_headers(fields : Array({String, String}), end_stream : Bool = false) : Nil
      response = @context.response
      wrap do
        fields.each do |(name, value)|
          if name == ":status"
            response.status_code = value.to_i
          else
            response.headers.add(name, value)
          end
        end
        @headers_sent = true
        if end_stream
          response.content_length = 0
          finish
        else
          response.flush
        end
      end
    end

    def send_data(data : Bytes, end_stream : Bool = false) : Nil
      wrap do
        @context.response.write(data)
        @context.response.flush
        finish if end_stream
      end
    end

    def send_trailers(fields : Array({String, String})) : Nil
      raise TransportError.new("HTTP/1.1 responses cannot carry trailers")
    end

    def supports_trailers? : Bool
      false
    end

    def abort : Nil
      finish
    rescue TransportError
    end

    def stop_receiving : Nil
    end

    def closed? : Bool
      @closed
    end

    def on_abort(&block : -> Nil) : Nil
      # A browser going away is only noticed when writing fails.
    end

    def peer : String?
      @context.request.remote_address.try(&.to_s)
    end

    private def finish : Nil
      return if @closed
      @closed = true
      @context.response.close
    end

    private def wrap(&)
      yield
    rescue e : IO::Error
      @closed = true
      raise TransportError.new(e.message, cause: e)
    end
  end
end
