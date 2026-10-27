require "./support"

private alias HPACK = HTTP2::HPACK

private def hex(string)
  HTTP2Spec.hex(string)
end

private def table_entries(table : HPACK::DynamicTable) : Array({String, String})
  (0...table.length).map { |i| table[i].not_nil! }
end

private def write_integer(value, prefix, flags = 0_u8) : Bytes
  io = IO::Memory.new
  HPACK::Encoder.new.write_integer(io, value, prefix, flags)
  io.to_slice
end

private def read_integer(bytes : Bytes, prefix) : Int32
  HPACK::Decoder::Reader.new(bytes).read_integer(prefix)
end

private def expect_decompression_error(decoder = HPACK::Decoder.new, &)
  expect_raises(HPACK::DecompressionError) { yield decoder }
end

# A header block test case from RFC 7541 Appendix C.
private record Example, wire : String, headers : Array({String, String}), table : Array({String, String}), size : Int32

DATE_21    = "Mon, 21 Oct 2013 20:13:21 GMT"
DATE_22    = "Mon, 21 Oct 2013 20:13:22 GMT"
LOCATION   = "https://www.example.com"
SET_COOKIE = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"

REQUEST_HEADERS = [
  [{":method", "GET"}, {":scheme", "http"}, {":path", "/"}, {":authority", "www.example.com"}],
  [{":method", "GET"}, {":scheme", "http"}, {":path", "/"}, {":authority", "www.example.com"}, {"cache-control", "no-cache"}],
  [{":method", "GET"}, {":scheme", "https"}, {":path", "/index.html"}, {":authority", "www.example.com"}, {"custom-key", "custom-value"}],
]

REQUEST_TABLES = [
  {[{":authority", "www.example.com"}], 57},
  {[{"cache-control", "no-cache"}, {":authority", "www.example.com"}], 110},
  {[{"custom-key", "custom-value"}, {"cache-control", "no-cache"}, {":authority", "www.example.com"}], 164},
]

RESPONSE_HEADERS = [
  [{":status", "302"}, {"cache-control", "private"}, {"date", DATE_21}, {"location", LOCATION}],
  [{":status", "307"}, {"cache-control", "private"}, {"date", DATE_21}, {"location", LOCATION}],
  [{":status", "200"}, {"cache-control", "private"}, {"date", DATE_22}, {"location", LOCATION}, {"content-encoding", "gzip"}, {"set-cookie", SET_COOKIE}],
]

RESPONSE_TABLES = [
  {[{"location", LOCATION}, {"date", DATE_21}, {"cache-control", "private"}, {":status", "302"}], 222},
  {[{":status", "307"}, {"location", LOCATION}, {"date", DATE_21}, {"cache-control", "private"}], 222},
  {[{"set-cookie", SET_COOKIE}, {"content-encoding", "gzip"}, {"date", DATE_22}], 215},
]

C3 = [
  "8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d",
  "8286 84be 5808 6e6f 2d63 6163 6865",
  "8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d 7661 6c75 65",
]

C4 = [
  "8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff",
  "8286 84be 5886 a8eb 1064 9cbf",
  "8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf",
]

C5 = [
  "4803 3330 3258 0770 7269 7661 7465 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133
   2032 303a 3133 3a32 3120 474d 546e 1768 7474 7073 3a2f 2f77 7777 2e65 7861 6d70
   6c65 2e63 6f6d",
  "4803 3330 37c1 c0bf",
  "88c1 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3220 474d
   54c0 5a04 677a 6970 7738 666f 6f3d 4153 444a 4b48 514b 425a 584f 5157 454f 5049
   5541 5851 5745 4f49 553b 206d 6178 2d61 6765 3d33 3630 303b 2076 6572 7369 6f6e
   3d31",
]

C6 = [
  "4882 6402 5885 aec3 771a 4b61 96d0 7abe 9410 54d4 44a8 2005 9504 0b81 66e0 82a6
   2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8 e9ae 82ae 43d3",
  "4883 640e ffc1 c0bf",
  "88c1 6196 d07a be94 1054 d444 a820 0595 040b 8166 e084 a62d 1bff c05a 839b d9ab
   77ad 94e7 821d d7f2 e6c7 b335 dfdf cd5b 3960 d5af 2708 7f36 72c1 ab27 0fb5 291f
   9587 3160 65c0 03ed 4ee5 b106 3d50 07",
]

private def check_sequence(decoder : HPACK::Decoder, wires : Array(String), headers, tables)
  wires.each_with_index do |wire, i|
    decoder.decode(hex(wire)).should eq(headers[i])
    entries, size = tables[i]
    table_entries(decoder.table).should eq(entries)
    decoder.table.size.should eq(size)
  end
end

describe HTTP2::HPACK do
  describe "integer representation (RFC 7541 C.1)" do
    it "C.1.1 encodes 10 using a 5-bit prefix" do
      write_integer(10, 5).should eq(Bytes[0x0a])
      read_integer(Bytes[0x0a], 5).should eq(10)
    end

    it "C.1.2 encodes 1337 using a 5-bit prefix" do
      write_integer(1337, 5).should eq(Bytes[0x1f, 0x9a, 0x0a])
      read_integer(Bytes[0x1f, 0x9a, 0x0a], 5).should eq(1337)
    end

    it "C.1.3 encodes 42 starting at an octet boundary" do
      write_integer(42, 8).should eq(Bytes[0x2a])
      read_integer(Bytes[0x2a], 8).should eq(42)
    end

    it "encodes values equal to the prefix maximum with a trailing zero octet" do
      write_integer(31, 5).should eq(Bytes[0x1f, 0x00])
      read_integer(Bytes[0x1f, 0x00], 5).should eq(31)
      write_integer(127, 7, 0x80_u8).should eq(Bytes[0xff, 0x00])
    end

    it "preserves flag bits above the prefix" do
      write_integer(3, 5, 0x20_u8).should eq(Bytes[0x23])
      read_integer(Bytes[0xe3], 5).should eq(3)
    end

    it "round trips values for every prefix size" do
      values = [0, 1, 2, 14, 15, 16, 30, 31, 32, 62, 63, 64, 126, 127, 128, 254, 255, 256, 1337, 16_383, 16_384, 2_097_151, 2_097_152, Int32::MAX]
      (1..8).each do |prefix|
        values.each do |value|
          read_integer(write_integer(value, prefix), prefix).should eq(value)
        end
      end
    end

    it "rejects integers overflowing 32 bits" do
      expect_raises(HPACK::DecompressionError, /overflow/) { read_integer(Bytes[0x1f, 0xff, 0xff, 0xff, 0xff, 0x0f], 5) }
      expect_raises(HPACK::DecompressionError, /overflow/) { read_integer(Bytes[0x1f, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01], 5) }
    end

    it "rejects truncated integers" do
      expect_raises(HPACK::DecompressionError, /Truncated/) { read_integer(Bytes[0x1f, 0x9a], 5) }
    end
  end

  describe "header field representations (RFC 7541 C.2)" do
    it "C.2.1 literal header field with indexing" do
      decoder = HPACK::Decoder.new
      decoder.decode(hex("400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572")).should eq([{"custom-key", "custom-header"}])
      table_entries(decoder.table).should eq([{"custom-key", "custom-header"}])
      decoder.table.size.should eq(55)
    end

    it "C.2.2 literal header field without indexing" do
      decoder = HPACK::Decoder.new
      decoder.decode(hex("040c 2f73 616d 706c 652f 7061 7468")).should eq([{":path", "/sample/path"}])
      decoder.table.length.should eq(0)
      decoder.table.size.should eq(0)
    end

    it "C.2.3 literal header field never indexed" do
      decoder = HPACK::Decoder.new
      decoder.decode(hex("1008 7061 7373 776f 7264 0673 6563 7265 74")).should eq([{"password", "secret"}])
      decoder.table.length.should eq(0)
    end

    it "C.2.4 indexed header field" do
      decoder = HPACK::Decoder.new
      decoder.decode(hex("82")).should eq([{":method", "GET"}])
      decoder.table.length.should eq(0)
    end
  end

  describe "request examples" do
    it "C.3 decodes requests without Huffman coding" do
      check_sequence(HPACK::Decoder.new, C3, REQUEST_HEADERS, REQUEST_TABLES)
    end

    it "C.4 decodes requests with Huffman coding" do
      check_sequence(HPACK::Decoder.new, C4, REQUEST_HEADERS, REQUEST_TABLES)
    end

    it "C.3 is reproduced exactly by the encoder without Huffman coding" do
      encoder = HPACK::Encoder.new(huffman: false)
      REQUEST_HEADERS.each_with_index do |headers, i|
        encoder.encode(headers).should eq(hex(C3[i]))
        entries, size = REQUEST_TABLES[i]
        table_entries(encoder.table).should eq(entries)
        encoder.table.size.should eq(size)
      end
    end

    it "C.4 is reproduced exactly by the encoder with Huffman coding" do
      encoder = HPACK::Encoder.new(huffman: true)
      REQUEST_HEADERS.each_with_index do |headers, i|
        encoder.encode(headers).should eq(hex(C4[i]))
      end
    end
  end

  describe "response examples (256 octet table with eviction)" do
    it "C.5 decodes responses without Huffman coding" do
      check_sequence(HPACK::Decoder.new(256), C5, RESPONSE_HEADERS, RESPONSE_TABLES)
    end

    it "C.6 decodes responses with Huffman coding" do
      check_sequence(HPACK::Decoder.new(256), C6, RESPONSE_HEADERS, RESPONSE_TABLES)
    end

    it "C.5.1 and C.5.2 are reproduced exactly by the encoder" do
      encoder = HPACK::Encoder.new(256, huffman: false)
      2.times do |i|
        encoder.encode(RESPONSE_HEADERS[i]).should eq(hex(C5[i]))
        entries, size = RESPONSE_TABLES[i]
        table_entries(encoder.table).should eq(entries)
        encoder.table.size.should eq(size)
      end
    end

    it "C.6.1 is reproduced exactly by the encoder" do
      encoder = HPACK::Encoder.new(256, huffman: true)
      encoder.encode(RESPONSE_HEADERS[0]).should eq(hex(C6[0]))
      # "307" is not shorter when Huffman coded, so the encoder sends it raw.
      encoder.encode(RESPONSE_HEADERS[1]).should eq(hex(C5[1]))
    end

    it "encodes the C.5.3 headers so that a decoder recovers them" do
      encoder = HPACK::Encoder.new(256)
      decoder = HPACK::Decoder.new(256)
      RESPONSE_HEADERS.each do |headers|
        decoder.decode(encoder.encode(headers)).should eq(headers)
        table_entries(decoder.table).should eq(table_entries(encoder.table))
      end
    end
  end

  describe HTTP2::HPACK::Huffman do
    it "encodes the RFC examples" do
      HPACK::Huffman.encode("www.example.com".to_slice).should eq(hex("f1e3 c2e5 f23a 6ba0 ab90 f4ff"))
      HPACK::Huffman.encode("no-cache".to_slice).should eq(hex("a8eb 1064 9cbf"))
      HPACK::Huffman.encode("custom-key".to_slice).should eq(hex("25a8 49e9 5ba9 7d7f"))
      HPACK::Huffman.encode("custom-value".to_slice).should eq(hex("25a8 49e9 5bb8 e8b4 bf"))
    end

    it "round trips the empty string" do
      HPACK::Huffman.encode(Bytes.empty).empty?.should be_true
      HPACK::Huffman.decode(Bytes.empty).empty?.should be_true
    end

    it "round trips every single octet" do
      256.times do |byte|
        data = Bytes[byte.to_u8]
        encoded = HPACK::Huffman.encode(data)
        encoded.size.should eq(HPACK::Huffman.encoded_size(data))
        HPACK::Huffman.decode(encoded).should eq(data)
      end
    end

    it "round trips random byte strings" do
      random = Random.new(1234)
      500.times do
        data = HTTP2Spec.random_bytes(random.rand(0..300), random)
        encoded = HPACK::Huffman.encode(data)
        encoded.size.should eq(HPACK::Huffman.encoded_size(data))
        HPACK::Huffman.decode(encoded).should eq(data)
      end
    end

    it "round trips random printable strings" do
      random = Random.new(99)
      200.times do
        data = String.build { |io| random.rand(0..100).times { io << (32 + random.rand(95)).chr } }.to_slice
        HPACK::Huffman.decode(HPACK::Huffman.encode(data)).should eq(data)
      end
    end

    it "rejects the EOS symbol" do
      # EOS is 30 one bits; 32 one bits contain it.
      expect_raises(HPACK::DecompressionError, /EOS/) { HPACK::Huffman.decode(Bytes[0xff, 0xff, 0xff, 0xff]) }
      # 'a' (00011) followed by EOS.
      expect_raises(HPACK::DecompressionError, /EOS/) { HPACK::Huffman.decode(Bytes[0x1f, 0xff, 0xff, 0xff, 0xff]) }
    end

    it "rejects padding longer than 7 bits" do
      expect_raises(HPACK::DecompressionError, /padding/) { HPACK::Huffman.decode(Bytes[0xff]) }
      # '0' (00000) then 11 bits of ones.
      expect_raises(HPACK::DecompressionError, /padding/) { HPACK::Huffman.decode(Bytes[0x07, 0xff]) }
    end

    it "rejects padding that is not a prefix of EOS" do
      # '0' is 00000; the remaining 3 bits must be ones.
      HPACK::Huffman.decode(Bytes[0x07]).should eq("0".to_slice)
      expect_raises(HPACK::DecompressionError, /padding/) { HPACK::Huffman.decode(Bytes[0x00]) }
      expect_raises(HPACK::DecompressionError, /padding/) { HPACK::Huffman.decode(Bytes[0x06]) }
      expect_raises(HPACK::DecompressionError, /padding/) { HPACK::Huffman.decode(Bytes[0x05]) }
    end

    it "rejects invalid Huffman data inside a header block" do
      decoder = HPACK::Decoder.new
      # Literal without indexing, new name "a" (Huffman), value with bad padding.
      expect_raises(HPACK::DecompressionError) { decoder.decode(Bytes[0x00, 0x81, 0x1f, 0x81, 0x00]) }
    end
  end

  describe HTTP2::HPACK::Decoder do
    it "rejects index 0" do
      expect_decompression_error { |d| d.decode(Bytes[0x80]) }
    end

    it "rejects indexes beyond the static and dynamic tables" do
      expect_decompression_error { |d| d.decode(Bytes[0xbe]) } # 62 with an empty dynamic table
      expect_decompression_error { |d| d.decode(write_integer(5000, 7, 0x80_u8)) }
    end

    it "rejects literal names referencing invalid indexes" do
      expect_decompression_error { |d| d.decode(Bytes[0x7e, 0x01, 0x61]) }       # with indexing, name index 62
      expect_decompression_error { |d| d.decode(Bytes[0x0f, 0x2f, 0x01, 0x61]) } # without indexing, name index 62
      expect_decompression_error { |d| d.decode(Bytes[0x1f, 0x2f, 0x01, 0x61]) } # never indexed, name index 62
    end

    it "resolves dynamic table indexes after the static table" do
      decoder = HPACK::Decoder.new
      decoder.decode(hex("400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572"))
      decoder.decode(Bytes[0xbe]).should eq([{"custom-key", "custom-header"}])
      expect_decompression_error(decoder) { |d| d.decode(Bytes[0xbf]) }
    end

    it "rejects truncated string literals" do
      expect_decompression_error { |d| d.decode(Bytes[0x40, 0x05, 0x61, 0x62]) }
      expect_decompression_error { |d| d.decode(Bytes[0x40, 0x01, 0x61]) } # missing value
      expect_decompression_error { |d| d.decode(Bytes[0x40]) }
    end

    it "allows table size updates at the start of a block" do
      decoder = HPACK::Decoder.new
      decoder.decode(Bytes[0x41, 0x01, 0x61]) # :authority: a
      decoder.table.length.should eq(1)
      decoder.decode(Bytes[0x20, 0x3f, 0xe1, 0x1f, 0x82]).should eq([{":method", "GET"}])
      decoder.table.max_size.should eq(4096)
      decoder.table.length.should eq(0) # evicted by the size 0 update
    end

    it "rejects a table size update after a header field" do
      expect_decompression_error { |d| d.decode(Bytes[0x82, 0x20]) }
      expect_decompression_error { |d| d.decode(Bytes[0x04, 0x01, 0x2f, 0x3f, 0x01]) }
    end

    it "rejects a table size update larger than the limit" do
      expect_decompression_error { |d| d.decode(write_integer(4097, 5, 0x20_u8)) }
      decoder = HPACK::Decoder.new(100)
      decoder.decode(write_integer(100, 5, 0x20_u8)).should be_empty
      expect_decompression_error(decoder) { |d| d.decode(write_integer(101, 5, 0x20_u8)) }
    end

    it "honours a lowered limit" do
      decoder = HPACK::Decoder.new
      decoder.max_table_size_limit = 0
      expect_decompression_error(decoder) { |d| d.decode(Bytes[0x21]) }
      decoder.decode(Bytes[0x20]).should be_empty
      decoder.table.max_size.should eq(0)
    end

    it "evicts entries when the table size shrinks" do
      decoder = HPACK::Decoder.new
      check_sequence(decoder, C3, REQUEST_HEADERS, REQUEST_TABLES)
      decoder.decode(write_integer(110, 5, 0x20_u8))
      table_entries(decoder.table).should eq([{"custom-key", "custom-value"}, {"cache-control", "no-cache"}])
      decoder.table.size.should eq(107)
      decoder.decode(write_integer(60, 5, 0x20_u8))
      table_entries(decoder.table).should eq([{"custom-key", "custom-value"}])
      decoder.table.size.should eq(54)
    end

    it "empties the table when an entry is larger than the table" do
      decoder = HPACK::Decoder.new(256)
      decoder.decode(Bytes[0x41, 0x01, 0x61])
      decoder.table.length.should eq(1)
      big = "x" * 300
      block = IO::Memory.new
      HPACK::Encoder.new(huffman: false).write_integer(block, 1, 6, 0x40_u8)
      HPACK::Encoder.new(huffman: false).write_string(block, big)
      decoder.decode(block.to_slice).should eq([{":authority", big}])
      decoder.table.length.should eq(0)
      decoder.table.size.should eq(0)
    end

    it "raises HeaderListTooLargeError but keeps the table in sync" do
      decoder = HPACK::Decoder.new(4096, 100)
      encoder = HPACK::Encoder.new
      headers = [{"x-big", "v" * 100}, {"x-small", "s"}]
      expect_raises(HPACK::HeaderListTooLargeError) { decoder.decode(encoder.encode(headers)) }
      table_entries(decoder.table).should eq(table_entries(encoder.table))
      decoder.max_header_list_size = Int32::MAX
      decoder.decode(encoder.encode(headers)).should eq(headers)
    end

    it "decodes an empty block" do
      HPACK::Decoder.new.decode(Bytes.empty).should be_empty
    end
  end

  describe HTTP2::HPACK::Encoder do
    it "uses the static table for full matches" do
      HPACK::Encoder.new.encode([{":method", "GET"}, {":path", "/"}, {":status", "200"}]).should eq(Bytes[0x82, 0x84, 0x88])
    end

    it "reuses dynamic table entries" do
      encoder = HPACK::Encoder.new(huffman: false)
      first = encoder.encode([{"x-custom", "value"}])
      first[0].should eq(0x40)
      encoder.encode([{"x-custom", "value"}]).should eq(Bytes[0xbe])
    end

    it "sends sensitive headers as never indexed" do
      encoder = HPACK::Encoder.new(huffman: false)
      decoder = HPACK::Decoder.new
      headers = [{"authorization", "Bearer secret"}, {"proxy-authorization", "Basic xyz"}, {"set-cookie", "a=b"},
                 {"cookie", "session=0123456789abcdefghij"}]
      2.times do
        block = encoder.encode(headers)
        decoder.decode(block).should eq(headers)
        encoder.table.length.should eq(0)
        decoder.table.length.should eq(0)
      end
      # Never indexed with a static name index (authorization = 23).
      encoder.encode([{"authorization", "x"}]).should eq(Bytes[0x1f, 0x08, 0x01, 0x78])
    end

    it "indexes short cookies" do
      encoder = HPACK::Encoder.new(huffman: false)
      encoder.encode([{"cookie", "a=b"}])
      table_entries(encoder.table).should eq([{"cookie", "a=b"}])
    end

    it "does not index very large fields" do
      encoder = HPACK::Encoder.new(huffman: false)
      decoder = HPACK::Decoder.new
      headers = [{"x-large", "v" * 2000}]
      block = encoder.encode(headers)
      block[0].should eq(0x00)
      decoder.decode(block).should eq(headers)
      encoder.table.length.should eq(0)
      decoder.table.length.should eq(0)
    end

    it "emits a table size update after peer_max_table_size= and stays in sync" do
      encoder = HPACK::Encoder.new
      decoder = HPACK::Decoder.new
      headers = [{"x-a", "1"}, {"x-b", "2"}]
      decoder.decode(encoder.encode(headers)).should eq(headers)
      decoder.table.length.should eq(2)

      encoder.peer_max_table_size = 0
      block = encoder.encode(headers)
      block[0].should eq(0x20)
      decoder.decode(block).should eq(headers)
      decoder.table.max_size.should eq(0)
      decoder.table.length.should eq(0)
      encoder.table.length.should eq(0)
    end

    it "signals the minimum size first when the size shrinks and grows again" do
      encoder = HPACK::Encoder.new(huffman: false)
      encoder.encode([{"x-a", "1"}])
      encoder.peer_max_table_size = 100
      encoder.peer_max_table_size = 4096
      block = encoder.encode([{":method", "GET"}])
      block.should eq(Bytes[0x3f, 0x45, 0x3f, 0xe1, 0x1f, 0x82])
      decoder = HPACK::Decoder.new
      decoder.decode(Bytes[0x40, 0x03, 0x78, 0x2d, 0x61, 0x01, 0x31])
      decoder.decode(block).should eq([{":method", "GET"}])
      decoder.table.max_size.should eq(4096)
    end

    it "emits only one update for repeated identical changes" do
      encoder = HPACK::Encoder.new(huffman: false)
      encoder.peer_max_table_size = 1000
      encoder.peer_max_table_size = 1000
      encoder.encode([{":method", "GET"}]).should eq(Bytes[0x3f, 0xc9, 0x07, 0x82])
      encoder.encode([{":method", "GET"}]).should eq(Bytes[0x82])
      encoder.peer_max_table_size = 1000
      encoder.encode([{":method", "GET"}]).should eq(Bytes[0x82])
    end

    it "never exceeds its own preferred maximum" do
      encoder = HPACK::Encoder.new(1024, huffman: false)
      encoder.peer_max_table_size = 65_536
      encoder.table.max_size.should eq(1024)
      encoder.peer_max_table_size = 512
      encoder.table.max_size.should eq(512)
      encoder.encode([{":method", "GET"}]).should eq(Bytes[0x3f, 0xe1, 0x03, 0x82])
    end

    it "round trips random header lists with table size changes" do
      random = Random.new(2024)
      names = ["x-a", "x-b", "content-type", ":path", "accept", "user-agent", "x-#{"long" * 10}", "cookie", "authorization"]
      encoder = HPACK::Encoder.new
      decoder = HPACK::Decoder.new
      300.times do |i|
        if i % 25 == 24
          size = [0, 64, 256, 1024, 4096].sample(random)
          encoder.peer_max_table_size = size
        end
        headers = Array.new(random.rand(0..12)) do
          value = String.build { |io| random.rand(0..60).times { io << (32 + random.rand(95)).chr } }.strip
          {names.sample(random), value}
        end
        decoder.decode(encoder.encode(headers)).should eq(headers)
        table_entries(decoder.table).should eq(table_entries(encoder.table))
        decoder.table.size.should eq(encoder.table.size)
        decoder.table.size.should be <= decoder.table.max_size
      end
    end
  end

  describe HTTP2::HPACK::DynamicTable do
    it "computes entry sizes with 32 octets of overhead" do
      HPACK::DynamicTable.entry_size("ab", "cde").should eq(37)
    end

    it "finds full and name matches" do
      table = HPACK::DynamicTable.new
      table.add("a", "1")
      table.add("b", "2")
      table.add("a", "3")
      table.find("a", "1").should eq({2, 2})
      table.find("a", "9").should eq({nil, 0})
      table.find("b", "2").should eq({1, 1})
      table.find("c", "1").should eq({nil, nil})
    end

    it "evicts the oldest entries first" do
      table = HPACK::DynamicTable.new(100)
      table.add("a", "1") # 34
      table.add("b", "2") # 34
      table.add("c", "3") # 34 -> evicts a
      table_entries(table).should eq([{"c", "3"}, {"b", "2"}])
      table.size.should eq(68)
      table[5].should be_nil
    end
  end
end
