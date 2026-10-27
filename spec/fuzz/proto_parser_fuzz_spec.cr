require "spec"
require "./protobuf_fuzz_support"

# Short, deterministic fuzz runs of the .proto tokenizer, parser, importer
# and generator, plus regressions for inputs found by longer campaigns
# (script/fuzz_protobuf.sh).
private def no_findings(campaign : ProtobufFuzz::Campaign)
  campaign.findings.first(3).each do |finding|
    puts "\n[#{finding.target}] #{finding.message}\ninput: #{String.new(finding.input).inspect[0, 600]}"
  end
  campaign.findings.size.should eq(0)
end

private def parse_error(source : String, message : String | Regex)
  error = expect_raises(Protobuf::Compiler::ParseError) do
    Protobuf::Compiler::Importer.new([] of String, sources: {"fuzz.proto" => source}).code_generator_request(["fuzz.proto"])
  end
  error.description.should match(message.is_a?(String) ? Regex.new(Regex.escape(message)) : message)
end

describe ".proto parser fuzzing" do
  it "raises only ParseError on mutated sources" do
    campaign = ProtobufFuzz::Campaign.new(20_261_026_u64)
    campaign.fuzz_proto(1_500)
    no_findings(campaign)
    campaign.accepted["proto"].should be > 10
  end

  it "accepts the seed sources" do
    campaign = ProtobufFuzz::Campaign.new(1_u64)
    ProtobufFuzz::Campaign::PROTO_SEEDS.each { |name, source| campaign.check_proto(name, source) }
    no_findings(campaign)
    campaign.rejected["proto"]?.should be_nil
  end

  describe "regressions" do
    it "limits the nesting of message declarations like protoc" do
      parse_error(%(syntax = "proto2";\n) + "message A { " * 5_000 + "}" * 5_000, "Reached maximum recursion limit for nested messages.")
      parse_error(%(syntax = "proto2";\nmessage M {\n) + "optional group G = 1 { " * 5_000 + "}" * 5_000 + "}", "Reached maximum recursion limit for nested messages.")
      Protobuf::Compiler::Parser.parse(%(syntax = "proto2";\n) + "message A { " * 31 + "}" * 31, "ok.proto")
    end

    it "limits the nesting of aggregate option values" do
      source = <<-PROTO
        syntax = "proto2";
        import "google/protobuf/descriptor.proto";
        message R { optional R r = 1; }
        extend google.protobuf.FileOptions { optional R rr = 5000; }
        option (rr) = #{"{ r " * 500}#{"}" * 500};
        PROTO
      parse_error(source, "Message is too deeply nested.")
    end

    it "reports invalid UTF-8 and stray bytes as ParseError" do
      campaign = ProtobufFuzz::Campaign.new(1_u64)
      campaign.check_proto("proto3.proto", String.new(Bytes[0xff, 0xfe, 0x00, 0x7b]))
      campaign.check_proto("proto3.proto", %(syntax = "proto3"; message M { string s = 1 [default = "\xff"]; }))
      no_findings(campaign)
    end
  end
end

describe ".proto parser fuzzing regressions (ranges and imports)" do
  it "rejects range ends that overflow like protoc" do
    parse_error(%(syntax = "proto2";\nmessage M { reserved 2147483647; }), "Field number out of bounds.")
    parse_error(%(syntax = "proto2";\nmessage M { extensions 1 to 2147483647; }), "Field number out of bounds.")
    parse_error(%(syntax = "proto2";\nmessage M { reserved 0x7fffffff to 30; }), "Field number out of bounds.")
  end

  it "validates reserved and extension ranges like protoc" do
    {
      "reserved 0;"                               => "Reserved numbers must be positive integers.",
      "reserved 536870912;"                       => "Reserved numbers must be positive integers.",
      "reserved 5 to 2;"                          => "Reserved range end number must be greater than start number.",
      "reserved 1 to 5, 3 to 8;"                  => "Reserved range 3 to 8 overlaps with already-defined range 1 to 5.",
      "extensions 536870912;"                     => "Extension numbers cannot be greater than 536870911.",
      "extensions 1 to 5; reserved 3;"            => "Extension range 1 to 5 overlaps with reserved range 3 to 3.",
      "extensions 1 to 5; extensions 4 to 6;"     => "Extension range 4 to 6 overlaps with already-defined range 1 to 5.",
      "reserved 2; optional int32 a = 2;"         => %(Field "a" uses reserved number 2.),
      %(reserved "a"; optional int32 a = 1;)      => %(Field name "a" is reserved.),
      "extensions 1 to 10; optional int32 a = 5;" => %(Extension range 1 to 10 includes field "a" (5).),
    }.each do |body, message|
      parse_error(%(syntax = "proto2";\nmessage M {\n  #{body}\n}\n), message)
    end
    parse_error(%(syntax = "proto2";\nenum E { A = 1; B = 5; reserved 5; }), %(Enum value "B" uses reserved number 5.))
    parse_error(%(syntax = "proto2";\nenum E { A = 1; reserved 7 to 3; }), "Reserved range end number must be greater than start number.")
  end

  it "rejects import paths with null bytes" do
    parse_error(%(syntax = "proto3";\nimport "a\\u0000b.proto";), "is not a valid path")
  end
end
