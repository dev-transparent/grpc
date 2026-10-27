require "./support"

private def decode(type, flags, stream_id, payload, max = HTTP2::DEFAULT_MAX_FRAME_SIZE)
  HTTP2Spec.decode_frame(HTTP2Spec.raw_frame(type, flags.to_u8, stream_id.to_u32, payload), max)
end

private def expect_connection_error(code : HTTP2::ErrorCode, &)
  error = expect_raises(HTTP2::ConnectionError) { yield }
  error.code.should eq(code)
  error
end

private def expect_stream_error(code : HTTP2::ErrorCode, stream_id, &)
  error = expect_raises(HTTP2::StreamError) { yield }
  error.code.should eq(code)
  error.stream_id.should eq(stream_id.to_u32)
  error
end

private alias FT = HTTP2::FrameType

describe HTTP2::Frame do
  describe "serialization" do
    it "writes the 9 octet frame header" do
      frame = HTTP2::DataFrame.new(0x01020304_u32, "abc".to_slice, end_stream: true)
      bytes = frame.to_slice
      bytes.size.should eq(12)
      bytes[0, 9].should eq(Bytes[0, 0, 3, 0, 1, 0x01, 0x02, 0x03, 0x04])
      String.new(bytes[9, 3]).should eq("abc")
    end

    it "encodes 24 bit lengths" do
      frame = HTTP2::DataFrame.new(1_u32, Bytes.new(0x012345))
      bytes = frame.to_slice
      bytes[0, 3].should eq(Bytes[0x01, 0x23, 0x45])
      HTTP2Spec.round_trip(frame).data.size.should eq(0x012345)
    end

    it "clears the reserved bit of the stream identifier when writing" do
      frame = HTTP2::DataFrame.new(0x80000001_u32, Bytes.empty)
      frame.to_slice[5].should eq(0)
    end

    it "ignores the reserved bit of the stream identifier when reading" do
      frame = decode(FT::DATA, 0, 0x80000003_u32, Bytes.empty).as(HTTP2::DataFrame)
      frame.stream_id.should eq(3)
    end
  end

  describe "round trips" do
    it "DATA" do
      frame = HTTP2Spec.round_trip(HTTP2::DataFrame.new(1_u32, "hello".to_slice))
      frame.stream_id.should eq(1)
      String.new(frame.data).should eq("hello")
      frame.end_stream?.should be_false
      frame.padding.should eq(0)
      frame.flags.should eq(0)
    end

    it "DATA with END_STREAM" do
      frame = HTTP2Spec.round_trip(HTTP2::DataFrame.new(7_u32, "x".to_slice, end_stream: true))
      frame.end_stream?.should be_true
      frame.flags.should eq(HTTP2::Flags::END_STREAM)
    end

    it "empty DATA" do
      frame = HTTP2Spec.round_trip(HTTP2::DataFrame.new(3_u32, Bytes.empty, end_stream: true))
      frame.data.empty?.should be_true
      frame.end_stream?.should be_true
    end

    it "padded DATA" do
      original = HTTP2::DataFrame.new(1_u32, "hello".to_slice, padding: 11)
      bytes = original.to_slice
      bytes.size.should eq(9 + 5 + 11)
      bytes[4].should eq(HTTP2::Flags::PADDED)
      bytes[9].should eq(10) # pad length octet
      bytes[15, 10].all?(&.zero?).should be_true
      frame = HTTP2Spec.round_trip(original)
      String.new(frame.data).should eq("hello")
      frame.padding.should eq(11)
      frame.flow_controlled_size.should eq(16)
    end

    it "DATA with only a pad length octet" do
      frame = decode(FT::DATA, HTTP2::Flags::PADDED, 1, Bytes[0]).as(HTTP2::DataFrame)
      frame.data.empty?.should be_true
      frame.padding.should eq(1)
      frame.flow_controlled_size.should eq(1)
    end

    it "DATA where the padding fills the payload" do
      frame = decode(FT::DATA, HTTP2::Flags::PADDED, 1, Bytes[4, 0, 0, 0, 0]).as(HTTP2::DataFrame)
      frame.data.empty?.should be_true
      frame.padding.should eq(5)
    end

    it "HEADERS" do
      frame = HTTP2Spec.round_trip(HTTP2::HeadersFrame.new(5_u32, Bytes[1, 2, 3], end_stream: true, end_headers: true))
      frame.stream_id.should eq(5)
      frame.fragment.should eq(Bytes[1, 2, 3])
      frame.end_stream?.should be_true
      frame.end_headers?.should be_true
      frame.priority.should be_nil
      frame.flags.should eq(HTTP2::Flags::END_STREAM | HTTP2::Flags::END_HEADERS)
    end

    it "HEADERS without END_HEADERS" do
      frame = HTTP2Spec.round_trip(HTTP2::HeadersFrame.new(5_u32, Bytes[1], end_stream: false, end_headers: false))
      frame.end_headers?.should be_false
      frame.end_stream?.should be_false
      frame.flags.should eq(0)
    end

    it "HEADERS with priority and padding" do
      priority = HTTP2::Priority.new(3_u32, 200_u8, true)
      original = HTTP2::HeadersFrame.new(5_u32, Bytes[9, 8, 7], priority: priority, padding: 4)
      original.payload_size.should eq(3 + 5 + 4)
      frame = HTTP2Spec.round_trip(original)
      frame.fragment.should eq(Bytes[9, 8, 7])
      frame.priority.should eq(priority)
      frame.padding.should eq(4)
      (frame.flags & HTTP2::Flags::PRIORITY).should_not eq(0)
      (frame.flags & HTTP2::Flags::PADDED).should_not eq(0)
    end

    it "HEADERS with non-exclusive priority" do
      priority = HTTP2::Priority.new(0x7fffffff_u32, 0_u8, false)
      frame = HTTP2Spec.round_trip(HTTP2::HeadersFrame.new(1_u32, Bytes.empty, priority: priority))
      frame.priority.should eq(priority)
    end

    it "PRIORITY" do
      priority = HTTP2::Priority.new(1_u32, 15_u8, true)
      frame = HTTP2Spec.round_trip(HTTP2::PriorityFrame.new(3_u32, priority))
      frame.stream_id.should eq(3)
      frame.priority.should eq(priority)
    end

    it "RST_STREAM" do
      frame = HTTP2Spec.round_trip(HTTP2::RstStreamFrame.new(3_u32, HTTP2::ErrorCode::CANCEL))
      frame.error_code.should eq(HTTP2::ErrorCode::CANCEL)
      frame.raw_error_code.should eq(8)
    end

    it "RST_STREAM with an unknown error code" do
      frame = HTTP2Spec.round_trip(HTTP2::RstStreamFrame.new(3_u32, 0xdead_u32))
      frame.raw_error_code.should eq(0xdead)
      frame.error_code.should eq(HTTP2::ErrorCode::INTERNAL_ERROR)
    end

    it "SETTINGS" do
      params = [{1_u16, 0_u32}, {3_u16, 100_u32}, {0xff_u16, 0xffffffff_u32}]
      frame = HTTP2Spec.round_trip(HTTP2::SettingsFrame.new(params))
      frame.stream_id.should eq(0)
      frame.ack?.should be_false
      frame.parameters.should eq(params)
    end

    it "SETTINGS ACK" do
      frame = HTTP2Spec.round_trip(HTTP2::SettingsFrame.ack)
      frame.ack?.should be_true
      frame.parameters.should be_empty
      HTTP2::SettingsFrame.ack.to_slice.should eq(Bytes[0, 0, 0, 4, 1, 0, 0, 0, 0])
    end

    it "PUSH_PROMISE" do
      frame = HTTP2Spec.round_trip(HTTP2::PushPromiseFrame.new(1_u32, 2_u32, Bytes[1, 2], end_headers: true))
      frame.stream_id.should eq(1)
      frame.promised_stream_id.should eq(2)
      frame.fragment.should eq(Bytes[1, 2])
      frame.end_headers?.should be_true
    end

    it "padded PUSH_PROMISE" do
      payload = Bytes[2, 0, 0, 0, 4, 0xaa, 0, 0]
      frame = decode(FT::PUSH_PROMISE, HTTP2::Flags::PADDED, 1, payload).as(HTTP2::PushPromiseFrame)
      frame.promised_stream_id.should eq(4)
      frame.fragment.should eq(Bytes[0xaa])
      frame.end_headers?.should be_false
    end

    it "PING" do
      data = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
      frame = HTTP2Spec.round_trip(HTTP2::PingFrame.new(data))
      frame.data.should eq(data)
      frame.ack?.should be_false
      ack = HTTP2Spec.round_trip(HTTP2::PingFrame.new(data, ack: true))
      ack.ack?.should be_true
    end

    it "rejects PING payloads that are not 8 octets on construction" do
      expect_raises(ArgumentError) { HTTP2::PingFrame.new(Bytes.new(7)) }
    end

    it "GOAWAY" do
      frame = HTTP2Spec.round_trip(HTTP2::GoawayFrame.new(0x7fffffff_u32, HTTP2::ErrorCode::ENHANCE_YOUR_CALM, "calm down".to_slice))
      frame.last_stream_id.should eq(0x7fffffff)
      frame.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM)
      String.new(frame.debug_data).should eq("calm down")
    end

    it "GOAWAY ignores the reserved bit of the last stream id" do
      payload = Bytes[0x80, 0, 0, 5, 0, 0, 0, 0]
      frame = decode(FT::GOAWAY, 0, 0, payload).as(HTTP2::GoawayFrame)
      frame.last_stream_id.should eq(5)
      frame.debug_data.empty?.should be_true
    end

    it "WINDOW_UPDATE" do
      frame = HTTP2Spec.round_trip(HTTP2::WindowUpdateFrame.new(0_u32, 0x7fffffff_u32))
      frame.stream_id.should eq(0)
      frame.increment.should eq(0x7fffffff)
      frame = HTTP2Spec.round_trip(HTTP2::WindowUpdateFrame.new(9_u32, 1_u32))
      frame.stream_id.should eq(9)
      frame.increment.should eq(1)
    end

    it "WINDOW_UPDATE ignores the reserved bit" do
      frame = decode(FT::WINDOW_UPDATE, 0, 1, Bytes[0x80, 0, 0, 1]).as(HTTP2::WindowUpdateFrame)
      frame.increment.should eq(1)
    end

    it "WINDOW_UPDATE with zero increment is parsed (rejected by the connection)" do
      frame = decode(FT::WINDOW_UPDATE, 0, 1, Bytes[0, 0, 0, 0]).as(HTTP2::WindowUpdateFrame)
      frame.increment.should eq(0)
    end

    it "CONTINUATION" do
      frame = HTTP2Spec.round_trip(HTTP2::ContinuationFrame.new(3_u32, Bytes[4, 5], end_headers: false))
      frame.fragment.should eq(Bytes[4, 5])
      frame.end_headers?.should be_false
      HTTP2Spec.round_trip(HTTP2::ContinuationFrame.new(3_u32, Bytes[4], end_headers: true)).end_headers?.should be_true
    end

    it "unknown frame types" do
      frame = decode(0xfa_u8, 0x5a, 7, Bytes[1, 2, 3]).as(HTTP2::UnknownFrame)
      frame.type.should eq(0xfa)
      frame.flags.should eq(0x5a)
      frame.stream_id.should eq(7)
      frame.payload.should eq(Bytes[1, 2, 3])
      HTTP2Spec.round_trip(frame).payload.should eq(Bytes[1, 2, 3])
    end

    it "ignores undefined flags" do
      frame = decode(FT::PING, 0xfe, 0, Bytes.new(8)).as(HTTP2::PingFrame)
      frame.ack?.should be_false
      frame = decode(FT::DATA, 0xf6, 1, Bytes[1]).as(HTTP2::DataFrame)
      frame.end_stream?.should be_false
      frame.data.should eq(Bytes[1])
    end

    it "reads consecutive frames from a stream" do
      io = IO::Memory.new
      HTTP2::SettingsFrame.new([{4_u16, 10_u32}]).write(io)
      HTTP2::PingFrame.new(Bytes.new(8, 1_u8)).write(io)
      HTTP2::DataFrame.new(1_u32, "x".to_slice, end_stream: true).write(io)
      io.rewind
      HTTP2::Frame.read(io).should be_a(HTTP2::SettingsFrame)
      HTTP2::Frame.read(io).should be_a(HTTP2::PingFrame)
      HTTP2::Frame.read(io).should be_a(HTTP2::DataFrame)
      HTTP2::Frame.read(io).should be_nil
    end
  end

  describe ".read" do
    it "returns nil on EOF before a frame header" do
      HTTP2::Frame.read(IO::Memory.new(Bytes.empty)).should be_nil
    end

    it "raises on a truncated frame header" do
      expect_raises(IO::EOFError) { HTTP2::Frame.read(IO::Memory.new(Bytes[0, 0, 4, 6])) }
    end

    it "raises on a truncated payload" do
      bytes = HTTP2Spec.raw_frame(FT::PING, 0, 0, Bytes.new(8))
      expect_raises(IO::EOFError) { HTTP2::Frame.read(IO::Memory.new(bytes[0, bytes.size - 1])) }
    end

    it "accepts frames of exactly max_frame_size" do
      frame = decode(FT::DATA, 0, 1, Bytes.new(16_384)).as(HTTP2::DataFrame)
      frame.data.size.should eq(16_384)
    end

    it "rejects frames larger than max_frame_size with FRAME_SIZE_ERROR" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::DATA, 0, 1, Bytes.new(16_385)) }
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::DATA, 0, 1, Bytes.new(101), max: 100) }
      decode(FT::DATA, 0, 1, Bytes.new(20_000), max: 20_000).should be_a(HTTP2::DataFrame)
    end

    it "rejects oversized frames of unknown types too" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(0xee_u8, 0, 0, Bytes.new(16_385)) }
    end
  end

  describe "malformed frames" do
    it "DATA on stream 0" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::DATA, 0, 0, Bytes[1]) }
    end

    it "padded DATA without a pad length octet" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::DATA, HTTP2::Flags::PADDED, 1, Bytes.empty) }
    end

    it "DATA with pad length equal to the payload length" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::DATA, HTTP2::Flags::PADDED, 1, Bytes[3, 0, 0]) }
    end

    it "DATA with pad length larger than the payload" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::DATA, HTTP2::Flags::PADDED, 1, Bytes[255, 1, 2]) }
    end

    it "HEADERS on stream 0" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::HEADERS, HTTP2::Flags::END_HEADERS, 0, Bytes[0x82]) }
    end

    it "padded HEADERS with an empty payload" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::HEADERS, HTTP2::Flags::PADDED, 1, Bytes.empty) }
    end

    it "HEADERS with pad length too large" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::HEADERS, HTTP2::Flags::PADDED | HTTP2::Flags::END_HEADERS, 1, Bytes[2, 0x82]) }
    end

    it "HEADERS with PRIORITY flag but fewer than 5 octets" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::HEADERS, HTTP2::Flags::PRIORITY, 1, Bytes[0, 0, 0, 1]) }
    end

    it "padded HEADERS with PRIORITY whose padding leaves no room for priority" do
      payload = Bytes[3, 0, 0, 0, 1, 0, 0]
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::HEADERS, HTTP2::Flags::PRIORITY | HTTP2::Flags::PADDED, 1, payload) }
    end

    it "PRIORITY on stream 0" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::PRIORITY, 0, 0, Bytes.new(5)) }
    end

    it "PRIORITY with the wrong length is a stream error" do
      expect_stream_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR, 3) { decode(FT::PRIORITY, 0, 3, Bytes.new(4)) }
      expect_stream_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR, 3) { decode(FT::PRIORITY, 0, 3, Bytes.new(6)) }
    end

    it "RST_STREAM on stream 0" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::RST_STREAM, 0, 0, Bytes.new(4)) }
    end

    it "RST_STREAM with the wrong length" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::RST_STREAM, 0, 1, Bytes.new(3)) }
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::RST_STREAM, 0, 1, Bytes.new(5)) }
    end

    it "SETTINGS on a non-zero stream" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::SETTINGS, 0, 1, Bytes.empty) }
    end

    it "SETTINGS ACK with a payload" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::SETTINGS, HTTP2::Flags::ACK, 0, Bytes.new(6)) }
    end

    it "SETTINGS with a length that is not a multiple of 6" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::SETTINGS, 0, 0, Bytes.new(5)) }
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::SETTINGS, 0, 0, Bytes.new(7)) }
    end

    it "PUSH_PROMISE on stream 0" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::PUSH_PROMISE, 0, 0, Bytes.new(4)) }
    end

    it "PUSH_PROMISE shorter than the promised stream id" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::PUSH_PROMISE, 0, 1, Bytes.new(3)) }
    end

    it "PUSH_PROMISE with pad length too large" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::PUSH_PROMISE, HTTP2::Flags::PADDED, 1, Bytes[5, 0, 0, 0, 2]) }
    end

    it "PING on a non-zero stream" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::PING, 0, 1, Bytes.new(8)) }
    end

    it "PING with the wrong length" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::PING, 0, 0, Bytes.new(7)) }
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::PING, HTTP2::Flags::ACK, 0, Bytes.new(9)) }
    end

    it "GOAWAY on a non-zero stream" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::GOAWAY, 0, 1, Bytes.new(8)) }
    end

    it "GOAWAY shorter than 8 octets" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::GOAWAY, 0, 0, Bytes.new(7)) }
    end

    it "WINDOW_UPDATE with the wrong length" do
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::WINDOW_UPDATE, 0, 0, Bytes.new(3)) }
      expect_connection_error(HTTP2::ErrorCode::FRAME_SIZE_ERROR) { decode(FT::WINDOW_UPDATE, 0, 1, Bytes.new(5)) }
    end

    it "CONTINUATION on stream 0" do
      expect_connection_error(HTTP2::ErrorCode::PROTOCOL_ERROR) { decode(FT::CONTINUATION, 0, 0, Bytes.empty) }
    end
  end
end

describe HTTP2::Settings do
  it "has the RFC defaults" do
    settings = HTTP2::Settings.new
    settings.header_table_size.should eq(4096)
    settings.enable_push?.should be_true
    settings.max_concurrent_streams.should be_nil
    settings.initial_window_size.should eq(65_535)
    settings.max_frame_size.should eq(16_384)
    settings.max_header_list_size.should be_nil
    settings.to_parameters.should be_empty
  end

  it "only lists non-default parameters" do
    settings = HTTP2::Settings.new(header_table_size: 0_u32, enable_push: false, max_concurrent_streams: 10_u32,
      initial_window_size: 1_u32, max_frame_size: 32_768_u32, max_header_list_size: 8192_u32)
    settings.to_parameters.should eq([{1_u16, 0_u32}, {2_u16, 0_u32}, {3_u16, 10_u32}, {4_u16, 1_u32}, {5_u16, 32_768_u32}, {6_u16, 8192_u32}])
  end

  it "applies parameters and ignores unknown ones" do
    settings = HTTP2::Settings.new
    settings.apply(1_u16, 100_u32)
    settings.apply(2_u16, 0_u32)
    settings.apply(3_u16, 5_u32)
    settings.apply(4_u16, 1000_u32)
    settings.apply(5_u16, 20_000_u32)
    settings.apply(6_u16, 300_u32)
    settings.apply(0x99_u16, 1_u32)
    settings.should eq(HTTP2::Settings.new(100_u32, false, 5_u32, 1000_u32, 20_000_u32, 300_u32))
  end

  it "validates ENABLE_PUSH" do
    HTTP2::Settings.validate(2_u16, 0_u32)
    HTTP2::Settings.validate(2_u16, 1_u32)
    error = expect_raises(HTTP2::ConnectionError) { HTTP2::Settings.validate(2_u16, 2_u32) }
    error.code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR)
  end

  it "validates INITIAL_WINDOW_SIZE" do
    HTTP2::Settings.validate(4_u16, 0x7fffffff_u32)
    error = expect_raises(HTTP2::ConnectionError) { HTTP2::Settings.validate(4_u16, 0x80000000_u32) }
    error.code.should eq(HTTP2::ErrorCode::FLOW_CONTROL_ERROR)
  end

  it "validates MAX_FRAME_SIZE" do
    HTTP2::Settings.validate(5_u16, 16_384_u32)
    HTTP2::Settings.validate(5_u16, 16_777_215_u32)
    expect_raises(HTTP2::ConnectionError) { HTTP2::Settings.validate(5_u16, 16_383_u32) }.code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR)
    expect_raises(HTTP2::ConnectionError) { HTTP2::Settings.validate(5_u16, 16_777_216_u32) }.code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR)
  end

  it "accepts any value for other settings" do
    HTTP2::Settings.validate(1_u16, 0xffffffff_u32)
    HTTP2::Settings.validate(3_u16, 0_u32)
    HTTP2::Settings.validate(6_u16, 0_u32)
    HTTP2::Settings.validate(0xabc_u16, 0xffffffff_u32)
  end
end

describe "HTTP2.error_code" do
  it "maps known codes and treats unknown codes as INTERNAL_ERROR" do
    HTTP2.error_code(0_u32).should eq(HTTP2::ErrorCode::NO_ERROR)
    HTTP2.error_code(0xd_u32).should eq(HTTP2::ErrorCode::HTTP_1_1_REQUIRED)
    HTTP2.error_code(0xe_u32).should eq(HTTP2::ErrorCode::INTERNAL_ERROR)
    HTTP2.error_code(0xffffffff_u32).should eq(HTTP2::ErrorCode::INTERNAL_ERROR)
  end
end
