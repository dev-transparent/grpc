require "compress/gzip"
require "compress/zlib"

module GRPC
  DEFAULT_MAX_RECEIVE_MESSAGE_SIZE = 4 * 1024 * 1024
  DEFAULT_MAX_SEND_MESSAGE_SIZE    = Int32::MAX

  # Message compression algorithms (`grpc-encoding`).
  module Compression
    IDENTITY  = "identity"
    SUPPORTED = ["gzip", "deflate", IDENTITY]
    # Value of `grpc-accept-encoding` advertised by this implementation.
    ACCEPT_ENCODING = SUPPORTED.join(",")

    def self.supported?(name : String) : Bool
      SUPPORTED.includes?(name)
    end

    def self.compress(name : String, data : Bytes) : Bytes
      io = IO::Memory.new
      case name
      when "gzip"
        Compress::Gzip::Writer.open(io) { |gzip| gzip.write(data) }
      when "deflate"
        Compress::Zlib::Writer.open(io) { |zlib| zlib.write(data) }
      when IDENTITY
        return data
      else
        raise Error.new(StatusCode::Unimplemented, "Unsupported compression #{name}")
      end
      io.to_slice
    end

    # Decompresses *data*, failing with RESOURCE_EXHAUSTED if the result
    # exceeds *max_size* octets.
    def self.decompress(name : String, data : Bytes, max_size : Int32) : Bytes
      reader = case name
               when "gzip"    then Compress::Gzip::Reader.new(IO::Memory.new(data))
               when "deflate" then Compress::Zlib::Reader.new(IO::Memory.new(data))
               when IDENTITY  then return data
               else
                 raise Error.new(StatusCode::Unimplemented, "Unsupported compression #{name}")
               end
      output = IO::Memory.new
      buffer = Bytes.new(16_384)
      while (read = reader.read(buffer)) > 0
        output.write(buffer[0, read])
        if output.size > max_size
          raise Error.new(StatusCode::ResourceExhausted, "Decompressed message larger than max (#{max_size})")
        end
      end
      output.to_slice
    rescue e : Compress::Deflate::Error | Compress::Gzip::Error | Compress::Zlib::Error | IO::Error
      raise Error.new(StatusCode::Internal, "Failed to decompress message: #{e.message}")
    end
  end

  # Length-prefixed message framing used on gRPC streams: a 1 octet
  # compressed flag, a 4 octet big-endian length and the message.
  module Framing
    HEADER_SIZE = 5

    # Writes a framed message. *compression* is the negotiated algorithm, or
    # `nil` to send the message uncompressed.
    def self.encode(message : Bytes, compression : String? = nil) : Bytes
      compressed = compression && compression != Compression::IDENTITY
      payload = compressed ? Compression.compress(compression.not_nil!, message) : message
      frame = Bytes.new(HEADER_SIZE + payload.size)
      frame[0] = compressed ? 1_u8 : 0_u8
      IO::ByteFormat::BigEndian.encode(payload.size.to_u32, frame[1, 4])
      payload.copy_to(frame + HEADER_SIZE)
      frame
    end

    # Reads the next framed message from *io*. Returns `nil` at end of
    # stream. *encoding* is the peer's `grpc-encoding`.
    def self.read(io : IO, encoding : String?, max_size : Int32) : Bytes?
      read_frame(io, encoding, max_size).try &.[0]
    end

    # Like `read`, but also returns whether the message was compressed.
    def self.read_frame(io : IO, encoding : String?, max_size : Int32) : {Bytes, Bool}?
      header = uninitialized UInt8[5]
      read = io.read(header.to_slice)
      return nil if read == 0
      begin
        io.read_fully(header.to_slice + read) if read < HEADER_SIZE
      rescue IO::EOFError
        raise Error.new(StatusCode::Internal, "Truncated message frame")
      end

      flag = header[0]
      length = IO::ByteFormat::BigEndian.decode(UInt32, header.to_slice[1, 4])
      if flag > 1
        raise Error.new(StatusCode::Internal, "Invalid message compression flag #{flag}")
      end
      if length > max_size
        raise Error.new(StatusCode::ResourceExhausted, "Received message larger than max (#{length} vs. #{max_size})")
      end

      payload = Bytes.new(length)
      begin
        io.read_fully(payload)
      rescue IO::EOFError
        raise Error.new(StatusCode::Internal, "Truncated message")
      end

      if flag == 1
        if encoding.nil? || encoding == Compression::IDENTITY
          raise Error.new(StatusCode::Internal, "Compressed message received without grpc-encoding")
        end
        payload = Compression.decompress(encoding, payload, max_size)
      end
      {payload, flag == 1}
    end
  end

  # Encoding and decoding of the `grpc-timeout` header.
  module Timeout
    UNITS = {
      'H' => 3600_i64 * 1_000_000_000,
      'M' => 60_i64 * 1_000_000_000,
      'S' => 1_000_000_000_i64,
      'm' => 1_000_000_i64,
      'u' => 1_000_i64,
      'n' => 1_i64,
    }

    # Encodes *span* using at most 8 digits, rounding up.
    def self.encode(span : Time::Span) : String
      total = span.total_nanoseconds.ceil
      # Spans of more than ~292 years would overflow Int64 nanoseconds below;
      # cap them at the largest encodable timeout.
      return "99999999H" if total >= (Int64::MAX - UNITS['H']).to_f
      nanos = Math.max(total.to_i64, 1_i64)
      {'n', 'u', 'm', 'S', 'M', 'H'}.each do |unit|
        size = UNITS[unit]
        value = (nanos + size - 1) // size
        return "#{value}#{unit}" if value < 100_000_000
      end
      "99999999H"
    end

    # Parses a `grpc-timeout` value, returning `nil` if it is malformed.
    def self.decode(value : String) : Time::Span?
      return nil if value.size < 2 || value.size > 9
      unit = UNITS[value[-1]]? || return nil
      digits = value[0..-2]
      return nil unless digits.each_char.all?(&.ascii_number?)
      amount = digits.to_i64
      # Clamp absurdly large timeouts instead of overflowing.
      return Time::Span.new(days: 36_500) if amount > Int64::MAX // unit
      Time::Span.new(nanoseconds: amount * unit)
    end
  end
end
