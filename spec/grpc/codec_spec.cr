require "./grpc_helper"

private def frame(flag : UInt8, payload : Bytes, length : UInt32? = nil) : Bytes
  io = IO::Memory.new
  io.write_byte(flag)
  io.write_bytes(length || payload.size.to_u32, IO::ByteFormat::BigEndian)
  io.write(payload)
  io.to_slice
end

describe GRPC::Compression do
  it "lists supported algorithms" do
    GRPC::Compression.supported?("gzip").should be_true
    GRPC::Compression.supported?("deflate").should be_true
    GRPC::Compression.supported?("identity").should be_true
    GRPC::Compression.supported?("snappy").should be_false
    GRPC::Compression::ACCEPT_ENCODING.should eq "gzip,deflate,identity"
  end

  {"gzip", "deflate", "identity"}.each do |algorithm|
    it "round trips #{algorithm}" do
      [Bytes.empty, "hello".to_slice, Bytes.new(100_000) { |i| (i % 7).to_u8 }].each do |data|
        compressed = GRPC::Compression.compress(algorithm, data)
        GRPC::Compression.decompress(algorithm, compressed, Int32::MAX).should eq data
      end
    end
  end

  it "actually compresses compressible data" do
    data = Bytes.new(100_000)
    GRPC::Compression.compress("gzip", data).size.should be < 1_000
    GRPC::Compression.compress("deflate", data).size.should be < 1_000
  end

  it "fails with RESOURCE_EXHAUSTED when decompressed data exceeds the limit" do
    data = Bytes.new(1_000_000)
    {"gzip", "deflate"}.each do |algorithm|
      compressed = GRPC::Compression.compress(algorithm, data)
      error = GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
        GRPC::Compression.decompress(algorithm, compressed, 100_000)
      end
      error.status.message.should contain "100000"
      GRPC::Compression.decompress(algorithm, compressed, 1_000_000).size.should eq 1_000_000
    end
  end

  it "fails with INTERNAL on corrupt data" do
    {"gzip", "deflate"}.each do |algorithm|
      GRPCSpec.expect_status(GRPC::StatusCode::Internal) do
        GRPC::Compression.decompress(algorithm, "definitely not compressed".to_slice, 1000)
      end
    end
  end

  it "fails with UNIMPLEMENTED for unsupported algorithms" do
    GRPCSpec.expect_status(GRPC::StatusCode::Unimplemented) { GRPC::Compression.compress("snappy", Bytes[1]) }
    GRPCSpec.expect_status(GRPC::StatusCode::Unimplemented) { GRPC::Compression.decompress("snappy", Bytes[1], 10) }
  end
end

describe GRPC::Framing do
  describe ".encode" do
    it "writes an uncompressed length-prefixed frame" do
      GRPC::Framing.encode("abc".to_slice).should eq Bytes[0, 0, 0, 0, 3, 'a'.ord, 'b'.ord, 'c'.ord]
      GRPC::Framing.encode(Bytes.empty).should eq Bytes[0, 0, 0, 0, 0]
      GRPC::Framing.encode("abc".to_slice, "identity")[0].should eq 0
    end

    it "sets the compressed flag and compresses with the given algorithm" do
      data = Bytes.new(10_000)
      encoded = GRPC::Framing.encode(data, "gzip")
      encoded[0].should eq 1
      length = IO::ByteFormat::BigEndian.decode(UInt32, encoded[1, 4])
      length.should eq encoded.size - 5
      GRPC::Compression.decompress("gzip", encoded + 5, Int32::MAX).should eq data
    end
  end

  describe ".read_frame" do
    it "reads consecutive frames and returns nil at end of stream" do
      io = IO::Memory.new
      io.write(GRPC::Framing.encode("one".to_slice))
      io.write(GRPC::Framing.encode(Bytes.empty))
      io.write(GRPC::Framing.encode("three".to_slice, "deflate"))
      io.rewind
      GRPC::Framing.read_frame(io, "deflate", 100).should eq({"one".to_slice, false})
      GRPC::Framing.read_frame(io, "deflate", 100).should eq({Bytes.empty, false})
      GRPC::Framing.read_frame(io, "deflate", 100).should eq({"three".to_slice, true})
      GRPC::Framing.read_frame(io, "deflate", 100).should be_nil
      GRPC::Framing.read(IO::Memory.new, nil, 100).should be_nil
    end

    it "reads frames delivered in tiny pieces" do
      reader, writer = IO.pipe
      data = GRPC::Framing.encode("fragmented".to_slice)
      spawn do
        data.each { |byte| writer.write_byte(byte); writer.flush; Fiber.yield }
        writer.close
      end
      GRPC::Framing.read(reader, nil, 100).should eq "fragmented".to_slice
      GRPC::Framing.read(reader, nil, 100).should be_nil
    end

    it "accepts uncompressed frames even when an encoding was negotiated" do
      io = IO::Memory.new(GRPC::Framing.encode("plain".to_slice))
      GRPC::Framing.read_frame(io, "gzip", 100).should eq({"plain".to_slice, false})
    end

    it "fails with INTERNAL on a truncated header" do
      [Bytes[0], Bytes[0, 0, 0, 0]].each do |bytes|
        error = GRPCSpec.expect_status(GRPC::StatusCode::Internal) { GRPC::Framing.read(IO::Memory.new(bytes), nil, 100) }
        error.status.message.should contain "Truncated"
      end
    end

    it "fails with INTERNAL on a truncated payload" do
      bytes = frame(0, "abc".to_slice, length: 10)
      error = GRPCSpec.expect_status(GRPC::StatusCode::Internal) { GRPC::Framing.read(IO::Memory.new(bytes), nil, 100) }
      error.status.message.should contain "Truncated"
    end

    it "fails with INTERNAL on an invalid compressed flag" do
      GRPCSpec.expect_status(GRPC::StatusCode::Internal) do
        GRPC::Framing.read(IO::Memory.new(frame(2, "abc".to_slice)), "gzip", 100)
      end
    end

    it "fails with RESOURCE_EXHAUSTED when the frame exceeds the max size" do
      GRPC::Framing.read(IO::Memory.new(frame(0, Bytes.new(100))), nil, 100).not_nil!.size.should eq 100
      GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
        GRPC::Framing.read(IO::Memory.new(frame(0, Bytes.new(101))), nil, 100)
      end
      # The length prefix alone is enough; no need to buffer the payload.
      GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
        GRPC::Framing.read(IO::Memory.new(frame(0, Bytes.empty, length: UInt32::MAX)), nil, 100)
      end
    end

    it "fails with RESOURCE_EXHAUSTED when the decompressed message exceeds the max size" do
      encoded = GRPC::Framing.encode(Bytes.new(10_000), "gzip")
      encoded.size.should be < 1_000
      GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
        GRPC::Framing.read(IO::Memory.new(encoded), "gzip", 1_000)
      end
    end

    it "fails with INTERNAL for a compressed frame without grpc-encoding" do
      encoded = GRPC::Framing.encode("abc".to_slice, "gzip")
      [nil, "identity"].each do |encoding|
        error = GRPCSpec.expect_status(GRPC::StatusCode::Internal) do
          GRPC::Framing.read(IO::Memory.new(encoded), encoding, 100)
        end
        error.status.message.should contain "grpc-encoding"
      end
    end

    it "fails with INTERNAL when the compressed payload is corrupt" do
      GRPCSpec.expect_status(GRPC::StatusCode::Internal) do
        GRPC::Framing.read(IO::Memory.new(frame(1, "garbage".to_slice)), "gzip", 100)
      end
    end
  end
end

describe GRPC::Timeout do
  describe ".encode" do
    it "uses the finest unit that fits in 8 digits" do
      GRPC::Timeout.encode(1.nanosecond).should eq "1n"
      GRPC::Timeout.encode(99_999_999.nanoseconds).should eq "99999999n"
      GRPC::Timeout.encode(100.milliseconds).should eq "100000u"
      GRPC::Timeout.encode(1.second).should eq "1000000u"
      GRPC::Timeout.encode(100.seconds).should eq "100000m"
      GRPC::Timeout.encode(1.day).should eq "86400000m"
      GRPC::Timeout.encode(2.days).should eq "172800S"
      GRPC::Timeout.encode(1200.days).should eq "1728000M"
    end

    it "never encodes more than 8 digits" do
      [1.nanosecond, 123_456_789.nanoseconds, 5.seconds, 3.hours, 1000.days, 100_000.days].each do |span|
        encoded = GRPC::Timeout.encode(span)
        encoded.size.should be <= 9
        encoded[0..-2].each_char.all?(&.ascii_number?).should be_true
      end
    end

    it "rounds up so that the timeout is never shortened" do
      GRPC::Timeout.encode(100_000_001.nanoseconds).should eq "100001u"
      GRPC::Timeout.encode(Time::Span.new(seconds: 100, nanoseconds: 1)).should eq "100001m"
      [100_000_001.nanoseconds, 1.second + 1.nanosecond, 2.days + 1.nanosecond, 123.hours + 7.nanoseconds].each do |span|
        GRPC::Timeout.decode(GRPC::Timeout.encode(span)).not_nil!.should be >= span
      end
    end

    it "encodes zero and negative spans as the smallest timeout" do
      GRPC::Timeout.encode(Time::Span.zero).should eq "1n"
      GRPC::Timeout.encode(-5.seconds).should eq "1n"
    end

    it "caps huge spans" do
      GRPC::Timeout.encode(100_000_000.hours * 2).should eq "99999999H"
      GRPC::Timeout.encode(Time::Span::MAX).should eq "99999999H"
      GRPC::Timeout.encode(200.days * 365).should eq "1752000H"
      GRPC::Timeout.encode(400.days * 365).should eq "99999999H"
      GRPC::Timeout.encode(99_999_999.minutes + 1.second).should eq "1666667H"
    end
  end

  describe ".decode" do
    it "decodes every unit" do
      GRPC::Timeout.decode("2H").should eq 2.hours
      GRPC::Timeout.decode("3M").should eq 3.minutes
      GRPC::Timeout.decode("4S").should eq 4.seconds
      GRPC::Timeout.decode("5m").should eq 5.milliseconds
      GRPC::Timeout.decode("6u").should eq 6.microseconds
      GRPC::Timeout.decode("7n").should eq 7.nanoseconds
      GRPC::Timeout.decode("0S").should eq Time::Span.zero
      GRPC::Timeout.decode("00000001m").should eq 1.millisecond
      GRPC::Timeout.decode("99999999S").should eq 99_999_999.seconds
    end

    it "rejects malformed values" do
      ["", "S", "1", "10", "1s", "1x", "-1S", "+1S", " 1S", "1 S", "1.5S", "1e3S", "S1",
       "123456789S", "１S"].each do |value|
        GRPC::Timeout.decode(value).should be_nil
      end
    end

    it "clamps values that would overflow" do
      span = GRPC::Timeout.decode("99999999H").not_nil!
      span.should be > 1000.days
      span.should be > Time::Span.zero
    end

    it "round trips encoded values exactly for whole units" do
      [1.nanosecond, 1.microsecond, 1.millisecond, 1.second, 1.minute, 1.hour, 7.days, 123_456.microseconds].each do |span|
        GRPC::Timeout.decode(GRPC::Timeout.encode(span)).should eq span
      end
    end
  end
end
