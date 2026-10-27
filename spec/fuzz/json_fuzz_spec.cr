require "spec"
require "./protobuf_fuzz_support"

# Short, deterministic fuzz runs of the JSON parser and printer, plus
# regressions for inputs found by longer campaigns (script/fuzz_protobuf.sh).
private def no_findings(campaign : ProtobufFuzz::Campaign)
  campaign.findings.first(3).each do |finding|
    puts "\n[#{finding.target}] #{finding.message}\ninput: #{String.new(finding.input).inspect[0, 400]}"
  end
  campaign.findings.size.should eq(0)
end

private alias P3 = ProtobufTestMessages::Proto3::TestAllTypesProto3

describe "protobuf JSON fuzzing" do
  it "keeps parsing and printing within their contracts on mutated documents" do
    campaign = ProtobufFuzz::Campaign.new(20_261_026_u64)
    campaign.fuzz_json(3_000)
    no_findings(campaign)
    campaign.accepted["json"].should be > 100
    campaign.rejected["json"].should be > 100
  end

  it "accepts the seed documents" do
    campaign = ProtobufFuzz::Campaign.new(1_u64)
    ProtobufFuzz::Campaign::JSON_SEEDS.each do |seed|
      campaign.check_json(seed.includes?("proto2") ? "protobuf_test_messages.proto2.TestAllTypesProto2" : "protobuf_test_messages.proto3.TestAllTypesProto3", seed)
    end
    no_findings(campaign)
  end

  describe "regressions" do
    it "rejects input that is not valid UTF-8" do
      input = String.new(%({"optionalString":"\xff"}).to_slice)
      expect_raises(Protobuf::JSON::ParseError, /UTF-8/) { P3.from_json(input) }
      expect_raises(Protobuf::JSON::ParseError, /UTF-8/) { P3.from_json(IO::Memory.new(input)) }
      expect_raises(Protobuf::JSON::ParseError, /UTF-8/) { P3.new.merge_from_json(input) }
    end

    it "rejects deeply nested documents with a ParseError" do
      expect_raises(Protobuf::JSON::ParseError) { Google::Protobuf::Value.from_json("[" * 5_000 + "]" * 5_000) }
      expect_raises(Protobuf::JSON::ParseError) { P3.from_json(%({"optionalValue":) + "{\"a\":" * 300 + "1" + "}" * 301) }
    end

    it "accepts floats that round to the largest float" do
      P3.from_json(%({"optionalFloat":3.4028235e38})).optional_float.should eq(Float32::MAX)
      P3.new(optional_float: Float32::MAX).to_json.should eq(%({"optionalFloat":3.4028235e+38}))
      expect_raises(Protobuf::JSON::ParseError, /out of range/) { P3.from_json(%({"optionalFloat":3.4028236e38})) }
    end

    it "reports huge numbers as out of range rather than invalid" do
      expect_raises(Protobuf::JSON::ParseError, /out of range/) { P3.from_json(%({"optionalDouble":1e999})) }
    end

    it "prints -0.0 so that every parser keeps the sign" do
      P3.new(optional_double: -0.0).to_json.should eq(%({"optionalDouble":-0.0}))
      P3.from_json(%({"optionalDouble":-0.0})).optional_double.sign_bit.should eq(-1)
    end
  end
end
