module HTTP2
  # Error codes defined in RFC 9113 section 7.
  enum ErrorCode : UInt32
    NO_ERROR            = 0x0
    PROTOCOL_ERROR      = 0x1
    INTERNAL_ERROR      = 0x2
    FLOW_CONTROL_ERROR  = 0x3
    SETTINGS_TIMEOUT    = 0x4
    STREAM_CLOSED       = 0x5
    FRAME_SIZE_ERROR    = 0x6
    REFUSED_STREAM      = 0x7
    CANCEL              = 0x8
    COMPRESSION_ERROR   = 0x9
    CONNECT_ERROR       = 0xa
    ENHANCE_YOUR_CALM   = 0xb
    INADEQUATE_SECURITY = 0xc
    HTTP_1_1_REQUIRED   = 0xd
  end

  # Base class of all HTTP/2 errors.
  class Error < Exception
    getter code : ErrorCode

    def initialize(@code : ErrorCode, message : String? = nil)
      super(message || code.to_s)
    end
  end

  # An error that affects the whole connection. The connection is terminated
  # with a GOAWAY frame carrying `code`.
  class ConnectionError < Error
  end

  # An error that only affects a single stream. The stream is terminated with
  # a RST_STREAM frame carrying `code`.
  class StreamError < Error
    getter stream_id : UInt32

    def initialize(@stream_id : UInt32, code : ErrorCode, message : String? = nil)
      super(code, message)
    end
  end

  # Raised when operating on a stream that was reset, either locally or by
  # the peer.
  class StreamResetError < Error
    getter stream_id : UInt32
    getter? remote : Bool

    def initialize(@stream_id : UInt32, code : ErrorCode, @remote : Bool)
      super(code, "Stream #{stream_id} reset by #{remote ? "peer" : "local endpoint"} (#{code})")
    end
  end

  # Raised when operating on a connection that has been closed.
  class ConnectionClosedError < Error
    def initialize(message = "Connection closed", code : ErrorCode = ErrorCode::NO_ERROR)
      super(code, message)
    end
  end

  # Raised by the client when the server refused or did not process a stream
  # (because of GOAWAY or REFUSED_STREAM). Such requests are safe to retry.
  class RefusedStreamError < Error
    def initialize(message = "Stream refused by peer")
      super(ErrorCode::REFUSED_STREAM, message)
    end
  end

  # Internal helper that turns a raw wire error code into an `ErrorCode`,
  # mapping unknown codes to INTERNAL_ERROR as allowed by RFC 9113 section 7.
  def self.error_code(raw : UInt32) : ErrorCode
    ErrorCode.from_value?(raw) || ErrorCode::INTERNAL_ERROR
  end
end

module HTTP2
  # Raised before sending a header block whose size (as defined for
  # SETTINGS_MAX_HEADER_LIST_SIZE: the sum of name and value lengths plus 32
  # octets per field) exceeds the limit advertised by the peer. Nothing is
  # sent; if the header block belonged to an open stream, the stream is
  # reset with INTERNAL_ERROR so the peer is not left waiting.
  class HeaderListSizeError < Error
    getter size : Int64
    getter limit : UInt32

    def initialize(@size : Int64, @limit : UInt32)
      super(ErrorCode::INTERNAL_ERROR, "Header list of #{size} octets exceeds the peer's SETTINGS_MAX_HEADER_LIST_SIZE of #{limit}")
    end
  end
end
