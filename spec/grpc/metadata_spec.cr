require "./grpc_helper"

describe GRPC::Metadata do
  it "treats keys case-insensitively and stores them lowercase" do
    metadata = GRPC::Metadata.new
    metadata["X-Custom-Key"] = "value"
    metadata["x-custom-key"].should eq "value"
    metadata["X-CUSTOM-KEY"]?.should eq "value"
    metadata.has_key?("x-Custom-key").should be_true
    metadata.keys.should eq ["x-custom-key"]
    metadata.to_a.should eq [{"x-custom-key", "value"}]
  end

  it "supports multiple values per key" do
    metadata = GRPC::Metadata.new
    metadata.add("x-multi", "a").add("X-Multi", "b").add("x-other", "c")
    metadata["x-multi"].should eq "a"
    metadata.get_all("x-multi").should eq ["a", "b"]
    metadata.size.should eq 3
    metadata.keys.should eq ["x-multi", "x-other"]
    metadata.to_h.should eq({"x-multi" => "a", "x-other" => "c"})

    metadata["x-multi"] = "replaced"
    metadata.get_all("x-multi").should eq ["replaced"]

    metadata.delete("X-MULTI")
    metadata.has_key?("x-multi").should be_false
    metadata.get_all("x-multi").should be_empty
    metadata["x-multi"]?.should be_nil
  end

  it "raises KeyError for a missing key" do
    expect_raises(KeyError) { GRPC::Metadata.new["missing"] }
  end

  it "builds from a hash and literal" do
    GRPC::Metadata.new({"A" => "1", "b" => "2"}).to_a.should eq [{"a", "1"}, {"b", "2"}]
    GRPC::Metadata{"key" => "v"}["key"].should eq "v"
  end

  it "dups independently and compares by entries" do
    original = GRPC::Metadata{"a" => "1"}
    copy = original.dup
    copy.add("b", "2")
    original.size.should eq 1
    copy.size.should eq 2
    original.should eq GRPC::Metadata{"a" => "1"}
    original.should_not eq copy
    GRPC::Metadata.new(original).should eq original
  end

  it "merges entries" do
    metadata = GRPC::Metadata{"a" => "1"}
    metadata.merge!(GRPC::Metadata{"a" => "2", "b" => "3"})
    metadata.get_all("a").should eq ["1", "2"]
    metadata["b"].should eq "3"
  end

  describe "key validation" do
    it "accepts lowercase letters, digits, '-', '_' and '.'" do
      GRPC::Metadata.validate_key("abc-def_ghi.jkl-0123").should eq "abc-def_ghi.jkl-0123"
      GRPC::Metadata.validate_key("UPPER").should eq "upper"
    end

    it "rejects empty keys and invalid characters" do
      ["", "with space", "colon:", "slash/", "ünïcode", "tab\t", ":path"].each do |key|
        expect_raises(GRPC::Metadata::InvalidError) { GRPC::Metadata.new.add(key, "v") }
      end
    end

    it "rejects reserved and grpc- prefixed keys" do
      ["content-type", "te", "user-agent", "grpc-timeout", "grpc-status", "grpc-message",
       "grpc-encoding", "grpc-accept-encoding", "grpc-status-details-bin", "grpc-custom",
       "Content-Type", "connection", "host"].each do |key|
        expect_raises(GRPC::Metadata::InvalidError, /Reserved/) { GRPC::Metadata.new[key] = "v" }
      end
    end
  end

  describe "value validation" do
    it "accepts printable ASCII values" do
      GRPC::Metadata.new.add("x-ok", " !~printable ASCII~! ")["x-ok"].should eq " !~printable ASCII~! "
    end

    it "rejects non-printable or non-ASCII values for non-binary keys" do
      ["line\nbreak", "tab\t", "\u007F", "ünïcode", "nul\0"].each do |value|
        expect_raises(GRPC::Metadata::InvalidError, /-bin/) { GRPC::Metadata.new.add("x-text", value) }
      end
    end

    it "accepts arbitrary bytes for -bin keys" do
      metadata = GRPC::Metadata.new
      metadata.add("x-data-bin", Bytes[0, 1, 0xfe, 0xff, 10])
      metadata["x-data-bin"].to_slice.should eq Bytes[0, 1, 0xfe, 0xff, 10]
      metadata["x-text-bin"] = "ünïcode\n"
      metadata["x-text-bin"].should eq "ünïcode\n"
    end
  end

  describe "#to_fields" do
    it "emits text values verbatim and binary values as unpadded base64" do
      metadata = GRPC::Metadata.new
      metadata.add("x-text", "hello")
      metadata.add("x-one-bin", Bytes[0xab])               # "qw=="
      metadata.add("x-two-bin", Bytes[0xab, 0xcd])         # "q80="
      metadata.add("x-three-bin", Bytes[0xab, 0xcd, 0xef]) # "q83v"
      metadata.add("x-empty-bin", Bytes.empty)
      metadata.to_fields.should eq [
        {"x-text", "hello"},
        {"x-one-bin", "qw"},
        {"x-two-bin", "q80"},
        {"x-three-bin", "q83v"},
        {"x-empty-bin", ""},
      ]
    end

    it "appends to an existing field list" do
      fields = [{":status", "200"}]
      GRPC::Metadata{"a" => "b"}.to_fields(fields).should be(fields)
      fields.should eq [{":status", "200"}, {"a", "b"}]
    end
  end

  describe ".from_fields" do
    it "skips pseudo-headers and reserved headers" do
      fields = [
        {":path", "/svc/m"}, {":authority", "x"}, {"content-type", "application/grpc"},
        {"te", "trailers"}, {"grpc-timeout", "1S"}, {"grpc-encoding", "gzip"},
        {"grpc-accept-encoding", "gzip"}, {"user-agent", "ua"}, {"grpc-status", "0"},
        {"grpc-message", "m"}, {"grpc-status-details-bin", "AA"},
        {"x-custom", "kept"}, {"x-custom", "twice"},
      ]
      metadata = GRPC::Metadata.from_fields(fields)
      metadata.to_a.should eq [{"x-custom", "kept"}, {"x-custom", "twice"}]
    end

    it "decodes padded and unpadded base64 binary values" do
      metadata = GRPC::Metadata.from_fields([
        {"a-bin", "qw=="}, {"b-bin", "qw"},
        {"c-bin", "q80="}, {"d-bin", "q80"},
        {"e-bin", "q83v"}, {"f-bin", ""},
      ])
      metadata["a-bin"].to_slice.should eq Bytes[0xab]
      metadata["b-bin"].to_slice.should eq Bytes[0xab]
      metadata["c-bin"].to_slice.should eq Bytes[0xab, 0xcd]
      metadata["d-bin"].to_slice.should eq Bytes[0xab, 0xcd]
      metadata["e-bin"].to_slice.should eq Bytes[0xab, 0xcd, 0xef]
      metadata["f-bin"].should eq ""
    end

    it "drops undecodable binary values" do
      metadata = GRPC::Metadata.from_fields([{"bad-bin", "!!!not base64!!!"}, {"good", "v"}])
      metadata.has_key?("bad-bin").should be_false
      metadata["good"].should eq "v"
    end

    it "round trips with to_fields" do
      metadata = GRPC::Metadata.new
      metadata.add("x-text", "value")
      metadata.add("x-text", "second")
      (0..5).each { |n| metadata.add("x-#{n}-bin", Bytes.new(n) { |i| (0xf0 + i).to_u8 }) }
      GRPC::Metadata.from_fields(metadata.to_fields).should eq metadata
    end
  end

  it "inspects readably" do
    GRPC::Metadata{"a" => "b"}.inspect.should eq %(GRPC::Metadata{"a" => "b"})
  end
end
