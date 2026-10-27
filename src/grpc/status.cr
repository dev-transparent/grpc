module GRPC
  # gRPC status codes (https://grpc.github.io/grpc/core/md_doc_statuscodes.html).
  enum StatusCode
    Ok                 =  0
    Cancelled          =  1
    Unknown            =  2
    InvalidArgument    =  3
    DeadlineExceeded   =  4
    NotFound           =  5
    AlreadyExists      =  6
    PermissionDenied   =  7
    ResourceExhausted  =  8
    FailedPrecondition =  9
    Aborted            = 10
    OutOfRange         = 11
    Unimplemented      = 12
    Internal           = 13
    Unavailable        = 14
    DataLoss           = 15
    Unauthenticated    = 16

    # Maps an HTTP status to a gRPC status code, for responses that do not
    # carry a `grpc-status` (https://github.com/grpc/grpc/blob/master/doc/http-grpc-status-mapping.md).
    def self.from_http_status(status : Int32) : StatusCode
      case status
      when 400           then Internal
      when 401           then Unauthenticated
      when 403           then PermissionDenied
      when 404           then Unimplemented
      when 429           then Unavailable
      when 502, 503, 504 then Unavailable
      else                    Unknown
      end
    end
  end

  # The status of a completed RPC.
  struct Status
    getter code : StatusCode
    getter message : String
    # Serialized `google.rpc.Status` sent in `grpc-status-details-bin`.
    getter details : Bytes?

    def initialize(@code : StatusCode, @message : String = "", @details : Bytes? = nil)
    end

    def self.ok : Status
      new(StatusCode::Ok)
    end

    def ok? : Bool
      code.ok?
    end

    def to_s(io : IO) : Nil
      io << code
      io << ": " << message unless message.empty?
    end

    # Encodes a status message for the `grpc-message` header: bytes outside
    # printable ASCII and `%` are percent-encoded.
    def self.encode_message(message : String) : String
      String.build do |io|
        message.each_byte do |byte|
          if 0x20 <= byte <= 0x7e && byte != '%'.ord
            io.write_byte(byte)
          else
            io << '%'
            io << byte.to_s(16, upcase: true).rjust(2, '0')
          end
        end
      end
    end

    # Decodes a percent-encoded `grpc-message` header. Invalid escapes are
    # passed through unchanged.
    def self.decode_message(encoded : String) : String
      return encoded unless encoded.includes?('%')
      bytes = encoded.to_slice
      io = IO::Memory.new(bytes.size)
      i = 0
      while i < bytes.size
        byte = bytes[i]
        if byte == '%'.ord && i + 2 < bytes.size &&
           (hi = hex_value(bytes[i + 1])) && (lo = hex_value(bytes[i + 2]))
          io.write_byte((hi << 4 | lo).to_u8)
          i += 3
        else
          io.write_byte(byte)
          i += 1
        end
      end
      String.new(io.to_slice)
    end

    private def self.hex_value(byte : UInt8) : Int32?
      case byte
      when '0'.ord..'9'.ord then (byte - '0'.ord).to_i32
      when 'a'.ord..'f'.ord then (byte - 'a'.ord + 10).to_i32
      when 'A'.ord..'F'.ord then (byte - 'A'.ord + 10).to_i32
      end
    end
  end

  # An RPC failure carrying a gRPC status. Raise it from a service method to
  # return a non-OK status to the client; clients raise it when a call fails.
  #
  # ```
  # raise GRPC::Error.new(:not_found, "No such user")
  # ```
  class Error < Exception
    getter status : Status
    # Trailing metadata received with (or to be sent with) the status.
    getter metadata : Metadata

    def initialize(code : StatusCode, message : String = "", details : Bytes? = nil, metadata : Metadata? = nil)
      initialize(Status.new(code, message, details), metadata)
    end

    def initialize(@status : Status, metadata : Metadata? = nil)
      @metadata = metadata || Metadata.new
      super(status.message.empty? ? status.code.to_s : "#{status.code}: #{status.message}")
    end

    def code : StatusCode
      status.code
    end

    def details : Bytes?
      status.details
    end
  end
end
