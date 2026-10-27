module HTTP2
  # Validation of HTTP semantics carried in header blocks (RFC 9113 section 8).
  # Each method raises `StreamError(PROTOCOL_ERROR)` for malformed messages.
  module HeaderValidation
    extend self

    REQUEST_PSEUDO_HEADERS  = Set{":method", ":scheme", ":authority", ":path", ":protocol"}
    RESPONSE_PSEUDO_HEADERS = Set{":status"}
    CONNECTION_HEADERS      = Set{"connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"}

    # Result of validating a request header block.
    record RequestHead,
      method : String,
      scheme : String?,
      authority : String?,
      path : String?,
      protocol : String?,
      headers : Array({String, String}),
      content_length : Int64?

    # Result of validating a response header block.
    record ResponseHead,
      status : Int32,
      headers : Array({String, String}),
      content_length : Int64?

    def validate_request(stream_id : UInt32, fields : Array({String, String})) : RequestHead
      pseudo = {} of String => String
      regular = [] of {String, String}
      split(stream_id, fields, REQUEST_PSEUDO_HEADERS, pseudo, regular)

      method = pseudo[":method"]? || malformed(stream_id, "missing :method")
      scheme = pseudo[":scheme"]?
      path = pseudo[":path"]?
      authority = pseudo[":authority"]?
      protocol = pseudo[":protocol"]?

      if method == "CONNECT" && protocol.nil?
        malformed(stream_id, "CONNECT request must not include :scheme or :path") if scheme || path
        malformed(stream_id, "CONNECT request requires :authority") unless authority
      else
        malformed(stream_id, "missing :scheme") unless scheme
        malformed(stream_id, "missing :path") unless path
        malformed(stream_id, "empty :path") if path.empty?
        malformed(stream_id, ":protocol requires CONNECT") if protocol && method != "CONNECT"
      end

      host = regular.find { |(name, _)| name == "host" }
      if authority && host && host[1] != authority
        malformed(stream_id, "host header does not match :authority")
      end

      RequestHead.new(method, scheme, authority, path, protocol, regular, content_length(stream_id, regular))
    end

    def validate_response(stream_id : UInt32, fields : Array({String, String})) : ResponseHead
      pseudo = {} of String => String
      regular = [] of {String, String}
      split(stream_id, fields, RESPONSE_PSEUDO_HEADERS, pseudo, regular)

      raw_status = pseudo[":status"]? || malformed(stream_id, "missing :status")
      unless raw_status.size == 3 && raw_status.each_char.all?(&.ascii_number?)
        malformed(stream_id, "invalid :status #{raw_status.inspect}")
      end
      ResponseHead.new(raw_status.to_i, regular, content_length(stream_id, regular))
    end

    def validate_trailers(stream_id : UInt32, fields : Array({String, String})) : Array({String, String})
      fields.each do |(name, value)|
        malformed(stream_id, "pseudo-header #{name} in trailers") if name.starts_with?(':')
        validate_field(stream_id, name, value)
      end
      fields
    end

    private def split(stream_id, fields, allowed, pseudo, regular)
      fields.each do |(name, value)|
        if name.starts_with?(':')
          malformed(stream_id, "pseudo-header #{name} after regular header") unless regular.empty?
          malformed(stream_id, "unknown pseudo-header #{name}") unless allowed.includes?(name)
          malformed(stream_id, "duplicate pseudo-header #{name}") if pseudo.has_key?(name)
          validate_value(stream_id, name, value)
          pseudo[name] = value
        else
          validate_field(stream_id, name, value)
          regular << {name, value}
        end
      end
    end

    private def validate_field(stream_id, name : String, value : String) : Nil
      malformed(stream_id, "empty header name") if name.empty?
      name.each_byte do |byte|
        unless token_byte?(byte)
          malformed(stream_id, "invalid header name #{name.inspect}")
        end
      end
      malformed(stream_id, "connection-specific header #{name}") if CONNECTION_HEADERS.includes?(name)
      malformed(stream_id, "te header with value other than trailers") if name == "te" && value != "trailers"
      validate_value(stream_id, name, value)
    end

    private def validate_value(stream_id, name : String, value : String) : Nil
      return if value.empty?
      bytes = value.to_slice
      if whitespace?(bytes[0]) || whitespace?(bytes[-1])
        malformed(stream_id, "header #{name} has leading or trailing whitespace")
      end
      bytes.each do |byte|
        if byte == 0 || byte == '\r'.ord || byte == '\n'.ord
          malformed(stream_id, "header #{name} contains invalid characters")
        end
      end
    end

    private def content_length(stream_id, headers) : Int64?
      length = nil
      headers.each do |(name, value)|
        next unless name == "content-length"
        parsed = value.each_char.all?(&.ascii_number?) && !value.empty? ? value.to_i64? : nil
        malformed(stream_id, "invalid content-length") unless parsed
        malformed(stream_id, "conflicting content-length") if length && length != parsed
        length = parsed
      end
      length
    end

    # Lowercase tchar (RFC 9110 section 5.6.2).
    private def token_byte?(byte : UInt8) : Bool
      case byte
      when 'a'.ord..'z'.ord, '0'.ord..'9'.ord
        true
      when '!'.ord, '#'.ord, '$'.ord, '%'.ord, '&'.ord, '\''.ord, '*'.ord, '+'.ord, '-'.ord,
           '.'.ord, '^'.ord, '_'.ord, '`'.ord, '|'.ord, '~'.ord
        true
      else
        false
      end
    end

    private def whitespace?(byte : UInt8) : Bool
      byte == ' '.ord || byte == '\t'.ord
    end

    private def malformed(stream_id, message) : NoReturn
      raise StreamError.new(stream_id, ErrorCode::PROTOCOL_ERROR, "Malformed message: #{message}")
    end
  end
end
