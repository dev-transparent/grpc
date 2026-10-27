require "base64"
require "http/server/handler"
require "http/server/request_processor"

class OpenSSL::SSL::Context::Server
  # Sets the ALPN protocols this server accepts, in order of preference
  # (e.g. `["h2", "http/1.1"]`).
  def alpn_protocols=(protocols : Enumerable(String)) : Nil
    io = IO::Memory.new
    protocols.each do |protocol|
      raise ArgumentError.new("Invalid ALPN protocol #{protocol.inspect}") unless 0 < protocol.bytesize < 256
      io.write_byte(protocol.bytesize.to_u8)
      io << protocol
    end
    self.alpn_protocol = io.to_slice
  end
end

module HTTP2
  # :nodoc:
  # An IO that first returns *prefix* (bytes consumed while detecting the
  # protocol) and then reads from *io*. Writes go straight to *io*.
  class PrefixedIO < IO
    getter io : IO
    getter remote_address : Socket::Address?
    getter local_address : Socket::Address?

    def initialize(@prefix : Bytes, @io : IO, @remote_address : Socket::Address? = nil, @local_address : Socket::Address? = nil)
      @offset = 0
    end

    def read(slice : Bytes) : Int32
      return 0 if slice.empty?
      if @offset < @prefix.size
        count = Math.min(slice.size, @prefix.size - @offset)
        slice.copy_from(@prefix.to_unsafe + @offset, count)
        @offset += count
        return count
      end
      @io.read(slice)
    end

    def write(slice : Bytes) : Nil
      @io.write(slice)
    end

    def flush : Nil
      @io.flush
    end

    def close : Nil
      @io.close
    end

    def closed? : Bool
      @io.closed?
    end
  end

  # HTTP/1.1 to HTTP/2 upgrade (h2c, RFC 7540 section 3.2) helpers.
  module H2C
    # Connection specific HTTP/1.1 header fields that must not be carried
    # over to HTTP/2.
    DROPPED_HEADERS = Set{"connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade",
                          "http2-settings", "host", "te"}

    # An HTTP/1.1 request that asked to be upgraded to HTTP/2.
    record Upgrade, fields : Array({String, String}), settings : Array({UInt16, UInt32})

    # Returns the upgrade if *request* is a valid h2c upgrade request:
    # `Upgrade: h2c`, exactly one `HTTP2-Settings` header that decodes to a
    # valid SETTINGS payload and a `Connection` header naming both. Invalid
    # upgrade requests are served as plain HTTP/1.1, as RFC 7540 permits.
    def self.parse(request : HTTP::Request) : Upgrade?
      headers = request.headers
      return nil unless tokens(headers, "Upgrade").includes?("h2c")
      connection = tokens(headers, "Connection")
      return nil unless connection.includes?("upgrade") && connection.includes?("http2-settings")
      values = headers.get?("HTTP2-Settings")
      return nil unless values && values.size == 1
      settings = decode_settings(values.first)
      return nil unless settings
      fields = request_fields(request)
      HeaderValidation.validate_request(1_u32, fields)
      Upgrade.new(fields, settings)
    rescue StreamError
      nil
    end

    # Decodes the base64url encoded SETTINGS payload of an `HTTP2-Settings`
    # header. Returns `nil` if it is malformed or contains invalid values.
    def self.decode_settings(value : String) : Array({UInt16, UInt32})?
      payload = Base64.decode(value.strip)
      return nil unless payload.size % 6 == 0
      params = (0...payload.size // 6).map do |i|
        {IO::ByteFormat::BigEndian.decode(UInt16, payload[i * 6, 2]),
         IO::ByteFormat::BigEndian.decode(UInt32, payload[i * 6 + 2, 4])}
      end
      params.each { |(id, val)| Settings.validate(id, val) }
      params
    rescue Base64::Error | ConnectionError
      nil
    end

    # Encodes *settings* for the `HTTP2-Settings` header.
    def self.encode_settings(settings : Settings) : String
      Base64.urlsafe_encode(SettingsFrame.new(settings.to_parameters).to_slice[FRAME_HEADER_SIZE..], padding: false)
    end

    # Converts an HTTP/1.1 request to HTTP/2 header fields.
    def self.request_fields(request : HTTP::Request) : Array({String, String})
      fields = [{":method", request.method}, {":scheme", "http"}]
      if host = request.headers["Host"]?
        fields << {":authority", host}
      end
      fields << {":path", request.resource}
      request.headers.each do |name, values|
        lower = name.downcase
        next if DROPPED_HEADERS.includes?(lower)
        values.each { |value| fields << {lower, value} }
      end
      fields
    end

    private def self.tokens(headers : HTTP::Headers, name : String) : Array(String)
      (headers.get?(name) || [] of String).flat_map(&.split(',')).map(&.strip.downcase)
    end
  end
end
