module HTTP2
  # Frame types defined in RFC 9113 section 6.
  enum FrameType : UInt8
    DATA          = 0x0
    HEADERS       = 0x1
    PRIORITY      = 0x2
    RST_STREAM    = 0x3
    SETTINGS      = 0x4
    PUSH_PROMISE  = 0x5
    PING          = 0x6
    GOAWAY        = 0x7
    WINDOW_UPDATE = 0x8
    CONTINUATION  = 0x9
  end

  # Frame flag bits.
  module Flags
    END_STREAM  =  0x1_u8
    ACK         =  0x1_u8
    END_HEADERS =  0x4_u8
    PADDED      =  0x8_u8
    PRIORITY    = 0x20_u8
  end

  FRAME_HEADER_SIZE      =                 9
  DEFAULT_MAX_FRAME_SIZE =            16_384
  MAX_ALLOWED_FRAME_SIZE =        16_777_215
  MAX_WINDOW_SIZE        = 2_147_483_647_i64
  MAX_STREAM_ID          =    0x7fffffff_u32

  # Stream dependency information carried by HEADERS and PRIORITY frames.
  # Priority signalling is deprecated by RFC 9113 and only validated.
  record Priority, stream_dependency : UInt32, weight : UInt8, exclusive : Bool

  # Base class for all frames.
  abstract class Frame
    getter stream_id : UInt32

    def initialize(@stream_id : UInt32)
    end

    abstract def type_code : UInt8
    abstract def flags : UInt8
    abstract def payload_size : Int32
    abstract def write_payload(io : IO) : Nil

    # Serializes the frame, including the 9 octet frame header, to *io*.
    def write(io : IO) : Nil
      size = payload_size
      io.write_byte((size >> 16).to_u8)
      io.write_byte((size >> 8).to_u8!)
      io.write_byte(size.to_u8!)
      io.write_byte(type_code)
      io.write_byte(flags)
      io.write_bytes(stream_id & MAX_STREAM_ID, IO::ByteFormat::BigEndian)
      write_payload(io)
    end

    # Returns the serialized frame.
    def to_slice : Bytes
      io = IO::Memory.new(FRAME_HEADER_SIZE + payload_size)
      write(io)
      io.to_slice
    end

    # Reads a single frame from *io*. Returns `nil` on a clean EOF before the
    # frame header. Raises `ConnectionError` or `StreamError` when the frame is
    # malformed.
    def self.read(io : IO, max_frame_size : Int32 = DEFAULT_MAX_FRAME_SIZE) : Frame?
      header = uninitialized UInt8[9]
      read = io.read(header.to_slice)
      return nil if read == 0
      io.read_fully(header.to_slice + read) if read < 9

      length = (header[0].to_i32 << 16) | (header[1].to_i32 << 8) | header[2].to_i32
      type = header[3]
      flags = header[4]
      stream_id = IO::ByteFormat::BigEndian.decode(UInt32, header.to_slice[5, 4]) & MAX_STREAM_ID

      if length > max_frame_size
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "Frame of #{length} octets exceeds maximum frame size #{max_frame_size}")
      end

      payload = Bytes.new(length)
      io.read_fully(payload)
      decode(type, flags, stream_id, payload)
    end

    # Decodes a frame from its components.
    def self.decode(type : UInt8, flags : UInt8, stream_id : UInt32, payload : Bytes) : Frame
      case FrameType.from_value?(type)
      when FrameType::DATA          then DataFrame.decode(flags, stream_id, payload)
      when FrameType::HEADERS       then HeadersFrame.decode(flags, stream_id, payload)
      when FrameType::PRIORITY      then PriorityFrame.decode(flags, stream_id, payload)
      when FrameType::RST_STREAM    then RstStreamFrame.decode(flags, stream_id, payload)
      when FrameType::SETTINGS      then SettingsFrame.decode(flags, stream_id, payload)
      when FrameType::PUSH_PROMISE  then PushPromiseFrame.decode(flags, stream_id, payload)
      when FrameType::PING          then PingFrame.decode(flags, stream_id, payload)
      when FrameType::GOAWAY        then GoawayFrame.decode(flags, stream_id, payload)
      when FrameType::WINDOW_UPDATE then WindowUpdateFrame.decode(flags, stream_id, payload)
      when FrameType::CONTINUATION  then ContinuationFrame.decode(flags, stream_id, payload)
      else
        UnknownFrame.new(type, flags, stream_id, payload)
      end
    end

    # Strips padding from a PADDED frame payload.
    protected def self.strip_padding(flags : UInt8, payload : Bytes) : {Bytes, Int32}
      return {payload, 0} if flags & Flags::PADDED == 0
      if payload.empty?
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "Padded frame without pad length")
      end
      pad_length = payload[0].to_i32
      if pad_length >= payload.size
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Padding length exceeds frame payload")
      end
      {payload[1, payload.size - 1 - pad_length], pad_length + 1}
    end

    protected def self.read_priority(payload : Bytes) : Priority
      raw = IO::ByteFormat::BigEndian.decode(UInt32, payload[0, 4])
      Priority.new(raw & MAX_STREAM_ID, payload[4], raw & 0x80000000_u32 != 0)
    end

    protected def self.require_stream(stream_id : UInt32, name : String) : Nil
      if stream_id == 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "#{name} frame with stream identifier 0")
      end
    end

    protected def self.require_connection(stream_id : UInt32, name : String) : Nil
      if stream_id != 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "#{name} frame with non-zero stream identifier")
      end
    end
  end

  # DATA frame (RFC 9113 section 6.1).
  class DataFrame < Frame
    getter data : Bytes
    getter? end_stream : Bool
    # The number of padding octets (including the pad length octet) that
    # were present on the wire. Counts against flow control.
    getter padding : Int32

    def initialize(stream_id : UInt32, @data : Bytes, @end_stream : Bool = false, @padding : Int32 = 0)
      super(stream_id)
    end

    def self.decode(flags, stream_id, payload)
      require_stream(stream_id, "DATA")
      data, padding = strip_padding(flags, payload)
      new(stream_id, data, flags & Flags::END_STREAM != 0, padding)
    end

    # Number of octets counted against flow control windows.
    def flow_controlled_size : Int32
      data.size + padding
    end

    def type_code : UInt8
      FrameType::DATA.value
    end

    def flags : UInt8
      f = 0_u8
      f |= Flags::END_STREAM if end_stream?
      f |= Flags::PADDED if padding > 0
      f
    end

    def payload_size : Int32
      data.size + padding
    end

    def write_payload(io : IO) : Nil
      if padding > 0
        io.write_byte((padding - 1).to_u8)
        io.write(data)
        (padding - 1).times { io.write_byte(0_u8) }
      else
        io.write(data)
      end
    end
  end

  # HEADERS frame (RFC 9113 section 6.2).
  class HeadersFrame < Frame
    getter fragment : Bytes
    getter? end_stream : Bool
    getter? end_headers : Bool
    getter priority : Priority?
    getter padding : Int32

    def initialize(stream_id : UInt32, @fragment : Bytes, @end_stream : Bool = false, @end_headers : Bool = true, @priority : Priority? = nil, @padding : Int32 = 0)
      super(stream_id)
    end

    def self.decode(flags, stream_id, payload)
      require_stream(stream_id, "HEADERS")
      data, padding = strip_padding(flags, payload)
      priority = nil
      if flags & Flags::PRIORITY != 0
        if data.size < 5
          raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "HEADERS frame too short for priority")
        end
        priority = read_priority(data)
        data = data + 5
      end
      new(stream_id, data, flags & Flags::END_STREAM != 0, flags & Flags::END_HEADERS != 0, priority, padding)
    end

    def type_code : UInt8
      FrameType::HEADERS.value
    end

    def flags : UInt8
      f = 0_u8
      f |= Flags::END_STREAM if end_stream?
      f |= Flags::END_HEADERS if end_headers?
      f |= Flags::PADDED if padding > 0
      f |= Flags::PRIORITY if priority
      f
    end

    def payload_size : Int32
      fragment.size + padding + (priority ? 5 : 0)
    end

    def write_payload(io : IO) : Nil
      io.write_byte((padding - 1).to_u8) if padding > 0
      if p = priority
        dep = p.stream_dependency & MAX_STREAM_ID
        dep |= 0x80000000_u32 if p.exclusive
        io.write_bytes(dep, IO::ByteFormat::BigEndian)
        io.write_byte(p.weight)
      end
      io.write(fragment)
      (padding - 1).times { io.write_byte(0_u8) } if padding > 0
    end
  end

  # PRIORITY frame (RFC 9113 section 6.3).
  class PriorityFrame < Frame
    getter priority : Priority

    def initialize(stream_id : UInt32, @priority : Priority)
      super(stream_id)
    end

    def self.decode(flags, stream_id, payload)
      require_stream(stream_id, "PRIORITY")
      if payload.size != 5
        raise StreamError.new(stream_id, ErrorCode::FRAME_SIZE_ERROR, "PRIORITY frame must be 5 octets")
      end
      new(stream_id, read_priority(payload))
    end

    def type_code : UInt8
      FrameType::PRIORITY.value
    end

    def flags : UInt8
      0_u8
    end

    def payload_size : Int32
      5
    end

    def write_payload(io : IO) : Nil
      dep = priority.stream_dependency & MAX_STREAM_ID
      dep |= 0x80000000_u32 if priority.exclusive
      io.write_bytes(dep, IO::ByteFormat::BigEndian)
      io.write_byte(priority.weight)
    end
  end

  # RST_STREAM frame (RFC 9113 section 6.4).
  class RstStreamFrame < Frame
    getter raw_error_code : UInt32

    def initialize(stream_id : UInt32, error_code : ErrorCode | UInt32)
      super(stream_id)
      @raw_error_code = error_code.is_a?(ErrorCode) ? error_code.value : error_code
    end

    def error_code : ErrorCode
      HTTP2.error_code(raw_error_code)
    end

    def self.decode(flags, stream_id, payload)
      require_stream(stream_id, "RST_STREAM")
      if payload.size != 4
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "RST_STREAM frame must be 4 octets")
      end
      new(stream_id, IO::ByteFormat::BigEndian.decode(UInt32, payload))
    end

    def type_code : UInt8
      FrameType::RST_STREAM.value
    end

    def flags : UInt8
      0_u8
    end

    def payload_size : Int32
      4
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(raw_error_code, IO::ByteFormat::BigEndian)
    end
  end

  # SETTINGS frame (RFC 9113 section 6.5).
  class SettingsFrame < Frame
    getter? ack : Bool
    getter parameters : Array({UInt16, UInt32})

    def initialize(@parameters : Array({UInt16, UInt32}) = [] of {UInt16, UInt32}, @ack : Bool = false)
      super(0_u32)
    end

    def self.ack : SettingsFrame
      new(ack: true)
    end

    def self.decode(flags, stream_id, payload)
      require_connection(stream_id, "SETTINGS")
      ack = flags & Flags::ACK != 0
      if ack && !payload.empty?
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "SETTINGS ACK with payload")
      end
      if payload.size % 6 != 0
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "SETTINGS payload not a multiple of 6 octets")
      end
      params = Array({UInt16, UInt32}).new(payload.size // 6)
      (payload.size // 6).times do |i|
        id = IO::ByteFormat::BigEndian.decode(UInt16, payload[i * 6, 2])
        value = IO::ByteFormat::BigEndian.decode(UInt32, payload[i * 6 + 2, 4])
        params << {id, value}
      end
      new(params, ack)
    end

    def type_code : UInt8
      FrameType::SETTINGS.value
    end

    def flags : UInt8
      ack? ? Flags::ACK : 0_u8
    end

    def payload_size : Int32
      parameters.size * 6
    end

    def write_payload(io : IO) : Nil
      parameters.each do |(id, value)|
        io.write_bytes(id, IO::ByteFormat::BigEndian)
        io.write_bytes(value, IO::ByteFormat::BigEndian)
      end
    end
  end

  # PUSH_PROMISE frame (RFC 9113 section 6.6).
  class PushPromiseFrame < Frame
    getter promised_stream_id : UInt32
    getter fragment : Bytes
    getter? end_headers : Bool

    def initialize(stream_id : UInt32, @promised_stream_id : UInt32, @fragment : Bytes, @end_headers : Bool = true)
      super(stream_id)
    end

    def self.decode(flags, stream_id, payload)
      require_stream(stream_id, "PUSH_PROMISE")
      data, _ = strip_padding(flags, payload)
      if data.size < 4
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "PUSH_PROMISE frame too short")
      end
      promised = IO::ByteFormat::BigEndian.decode(UInt32, data[0, 4]) & MAX_STREAM_ID
      new(stream_id, promised, data + 4, flags & Flags::END_HEADERS != 0)
    end

    def type_code : UInt8
      FrameType::PUSH_PROMISE.value
    end

    def flags : UInt8
      end_headers? ? Flags::END_HEADERS : 0_u8
    end

    def payload_size : Int32
      4 + fragment.size
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(promised_stream_id, IO::ByteFormat::BigEndian)
      io.write(fragment)
    end
  end

  # PING frame (RFC 9113 section 6.7).
  class PingFrame < Frame
    getter data : Bytes
    getter? ack : Bool

    def initialize(@data : Bytes = Bytes.new(8), @ack : Bool = false)
      super(0_u32)
      raise ArgumentError.new("PING payload must be 8 octets") unless @data.size == 8
    end

    def self.decode(flags, stream_id, payload)
      require_connection(stream_id, "PING")
      if payload.size != 8
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "PING frame must be 8 octets")
      end
      new(payload, flags & Flags::ACK != 0)
    end

    def type_code : UInt8
      FrameType::PING.value
    end

    def flags : UInt8
      ack? ? Flags::ACK : 0_u8
    end

    def payload_size : Int32
      8
    end

    def write_payload(io : IO) : Nil
      io.write(data)
    end
  end

  # GOAWAY frame (RFC 9113 section 6.8).
  class GoawayFrame < Frame
    getter last_stream_id : UInt32
    getter raw_error_code : UInt32
    getter debug_data : Bytes

    def initialize(@last_stream_id : UInt32, error_code : ErrorCode | UInt32, @debug_data : Bytes = Bytes.empty)
      super(0_u32)
      @raw_error_code = error_code.is_a?(ErrorCode) ? error_code.value : error_code
    end

    def error_code : ErrorCode
      HTTP2.error_code(raw_error_code)
    end

    def self.decode(flags, stream_id, payload)
      require_connection(stream_id, "GOAWAY")
      if payload.size < 8
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "GOAWAY frame too short")
      end
      last = IO::ByteFormat::BigEndian.decode(UInt32, payload[0, 4]) & MAX_STREAM_ID
      code = IO::ByteFormat::BigEndian.decode(UInt32, payload[4, 4])
      new(last, code, payload + 8)
    end

    def type_code : UInt8
      FrameType::GOAWAY.value
    end

    def flags : UInt8
      0_u8
    end

    def payload_size : Int32
      8 + debug_data.size
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(last_stream_id, IO::ByteFormat::BigEndian)
      io.write_bytes(raw_error_code, IO::ByteFormat::BigEndian)
      io.write(debug_data)
    end
  end

  # WINDOW_UPDATE frame (RFC 9113 section 6.9).
  class WindowUpdateFrame < Frame
    getter increment : UInt32

    def initialize(stream_id : UInt32, @increment : UInt32)
      super(stream_id)
    end

    def self.decode(flags, stream_id, payload)
      if payload.size != 4
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "WINDOW_UPDATE frame must be 4 octets")
      end
      new(stream_id, IO::ByteFormat::BigEndian.decode(UInt32, payload) & MAX_STREAM_ID)
    end

    def type_code : UInt8
      FrameType::WINDOW_UPDATE.value
    end

    def flags : UInt8
      0_u8
    end

    def payload_size : Int32
      4
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(increment, IO::ByteFormat::BigEndian)
    end
  end

  # CONTINUATION frame (RFC 9113 section 6.10).
  class ContinuationFrame < Frame
    getter fragment : Bytes
    getter? end_headers : Bool

    def initialize(stream_id : UInt32, @fragment : Bytes, @end_headers : Bool = true)
      super(stream_id)
    end

    def self.decode(flags, stream_id, payload)
      require_stream(stream_id, "CONTINUATION")
      new(stream_id, payload, flags & Flags::END_HEADERS != 0)
    end

    def type_code : UInt8
      FrameType::CONTINUATION.value
    end

    def flags : UInt8
      end_headers? ? Flags::END_HEADERS : 0_u8
    end

    def payload_size : Int32
      fragment.size
    end

    def write_payload(io : IO) : Nil
      io.write(fragment)
    end
  end

  # A frame of an unknown (extension) type. These must be ignored.
  class UnknownFrame < Frame
    getter type : UInt8
    getter payload : Bytes
    @flags : UInt8

    def initialize(@type : UInt8, @flags : UInt8, stream_id : UInt32, @payload : Bytes)
      super(stream_id)
    end

    def type_code : UInt8
      type
    end

    def flags : UInt8
      @flags
    end

    def payload_size : Int32
      payload.size
    end

    def write_payload(io : IO) : Nil
      io.write(payload)
    end
  end
end
