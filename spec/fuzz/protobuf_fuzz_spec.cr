require "spec"
require "./protobuf_fuzz_support"
require "./protobuf_python_differential"

# Short, deterministic (fixed seed) fuzz runs of the binary decoder, plus
# regressions for inputs found by longer campaigns (script/fuzz_protobuf.sh).
private def no_findings(campaign : ProtobufFuzz::Campaign | ProtobufFuzz::PythonDifferential)
  campaign.findings.first(3).each do |finding|
    puts "\n[#{finding.target}] #{finding.message}\ninput: #{finding.input.hexstring[0, 400]}"
  end
  campaign.findings.size.should eq(0)
end

describe "protobuf binary decoder fuzzing" do
  it "keeps decoding within its contract on mutated messages" do
    campaign = ProtobufFuzz::Campaign.new(20_261_026_u64)
    campaign.fuzz_binary(4_000)
    no_findings(campaign)
    campaign.accepted["binary"].should be > 100
    campaign.rejected["binary"].should be > 100
  end

  it "accepts the generated seed corpus" do
    campaign = ProtobufFuzz::Campaign.new(7_u64)
    campaign.binary_corpus.each { |(type, input)| campaign.check_binary(type, input) }
    no_findings(campaign)
    # A few generated strings are deliberately invalid UTF-8.
    campaign.accepted["binary"].should be > campaign.rejected["binary"] * 4
  end

  it "agrees with Python's decoder on mutated messages" do
    differential = ProtobufFuzz::PythonDifferential.new(20_261_026_u64)
    pending!("Python with protobuf and grpcio-tools is not available") unless differential.available?
    differential.run(150)
    no_findings(differential)
  end

  describe "regressions" do
    p3 = "protobuf_test_messages.proto3.TestAllTypesProto3"

    it "rejects overlong tags" do
      campaign = ProtobufFuzz::Campaign.new(1_u64)
      campaign.check_binary(p3, "888080808080808000d209".hexbytes)
      no_findings(campaign)
      campaign.rejected["binary"].should eq(1)
    end

    it "drops the overflowing bits of ten-byte varints, like protoc and upb" do
      message = ProtobufTestMessages::Proto3::TestAllTypesProto3.from_protobuf("08ffffffffffffffffff7f".hexbytes)
      message.optional_int32.should eq(-1)
    end

    it "rejects messages nested beyond the recursion limit, including groups" do
      message = ProtobufTestMessages::Proto3::TestAllTypesProto3.new
      100.times { message = ProtobufTestMessages::Proto3::TestAllTypesProto3.new(recursive_message: message) }
      ok = message.to_protobuf
      ProtobufTestMessages::Proto3::TestAllTypesProto3.from_protobuf(ok).should eq(message)
      too_deep = ProtobufTestMessages::Proto3::TestAllTypesProto3.new(recursive_message: message).to_protobuf
      expect_raises(Protobuf::DecodeError, /Recursion limit/) { ProtobufTestMessages::Proto3::TestAllTypesProto3.from_protobuf(too_deep) }
      groups = ("cb0c" * 200 + "cc0c" * 200).hexbytes # nested Data groups (field 201)
      expect_raises(Protobuf::DecodeError, /Recursion limit|Mismatched|Unterminated/) do
        ProtobufTestMessages::Proto2::TestAllTypesProto2.from_protobuf(groups)
      end
    end

    it "keeps unknown closed enum values in packed fields as sign-extended int32 varints" do
      message = ProtobufTestMessages::Proto2::TestAllTypesProto2.from_protobuf("a20309f894b798cee1a4c439".hexbytes)
      message.repeated_foreign_enum.should be_empty
      message.unknown_fields.should eq("a003f894b798feffffffff01".hexbytes)
    end

    it "refuses to print proto2 strings with invalid UTF-8 as JSON" do
      message = ProtobufTestMessages::Proto2::TestAllTypesProto2.from_protobuf("7201ff".hexbytes)
      expect_raises(Protobuf::JSON::SerializeError, /UTF-8/) { message.to_json }
      map = ProtobufTestMessages::Proto2::TestAllTypesProto2.from_protobuf("ca04050a01ff1200".hexbytes)
      expect_raises(Protobuf::JSON::SerializeError, /UTF-8/) { map.to_json }
    end

    it "bounds the nesting of Any values when printing JSON" do
      any = Google::Protobuf::Any.pack(Google::Protobuf::Duration.new(seconds: 1))
      200.times { any = Google::Protobuf::Any.pack(any) }
      decoded = Google::Protobuf::Any.from_protobuf(any.to_protobuf)
      expect_raises(Protobuf::JSON::SerializeError, /nested too deeply/) { decoded.to_json }
    end

    it "prints messages nested up to the recursion limit as JSON" do
      message = ProtobufTestMessages::Proto3::TestAllTypesProto3.new
      99.times { message = ProtobufTestMessages::Proto3::TestAllTypesProto3.new(recursive_message: message) }
      ProtobufTestMessages::Proto3::TestAllTypesProto3.from_json(message.to_json).should eq(message)
    end
  end
end
