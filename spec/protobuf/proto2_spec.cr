require "./protobuf_helper"

private alias P2 = SpecTest::Proto2
private alias Closed = SpecTest::Proto2::Closed
private alias TestP2 = ProtobufTestMessages::Proto2::TestAllTypesProto2

# A hand-written extendable message and extensions declared through the DSL.
@[Protobuf::TypeName("dsl.Host")]
class DslHost
  include Protobuf::Message

  field id : Int32, 1, optional: true
end

DSL_NOTE  = Protobuf::Extension(DslHost, String).new("dsl.note", 100)
DSL_SCORE = Protobuf::Extension(DslHost, Array(Int64)).new("dsl.scores", 101, type: :sint64, packed: true)

describe "proto2 and editions semantics" do
  describe "default values" do
    it "keeps unset fields nil and exposes defaults through <name>_or_default" do
      message = P2::Defaults.new
      message.i32.should be_nil
      message.i32_or_default.should eq(-16)
      message.u32_or_default.should eq(15_u32)
      message.i64_or_default.should eq(Int64::MIN)
      message.u64_or_default.should eq(UInt64::MAX)
      message.s32_or_default.should eq(-7)
      message.f64_or_default.should eq(UInt64::MAX)
      message.f_or_default.should eq(1e10_f32)
      message.d_or_default.should eq(-Float64::INFINITY)
      message.nan_or_default.nan?.should be_true
      message.tiny_or_default.should eq(1e-300)
      message.b_or_default.should be_true
      message.s_or_default.should eq("a\"b\\c\n\#{x}é")
      message.by_or_default.should eq(Bytes[0, 255, 39, 34, 9])
      message.e_or_default.should eq(Closed::CLOSED_ONE)
      message.in_oneof_or_default.should eq(3)
      message.to_protobuf.should be_empty
    end

    it "uses the zero value, or the first enum value, without an explicit default" do
      P2::Defaults.new.none_or_default.should eq("")
      P2::Defaults.new.first_or_default.should eq(Closed::CLOSED_ZERO)
      SpecTest::Proto2::Closedness.new.with_default_or_default.should eq(Closed::CLOSED_FIVE)
    end

    it "returns the set value, even when it equals the default" do
      message = P2::Defaults.new(i32: 5, b: false, s: "")
      message.i32_or_default.should eq(5)
      message.b_or_default.should be_false
      message.s_or_default.should eq("")
      P2::Defaults.from_protobuf(P2::Defaults.new(i32: -16).to_protobuf).i32.should eq(-16)
    end

    it "returns a fresh copy of bytes defaults" do
      message = P2::Defaults.new
      bytes = message.by_or_default
      bytes[0] = 7_u8
      message.by_or_default[0].should eq(0)
    end

    it "gives proto3 optional and editions explicit fields a zero default" do
      SpecTest::Optionals.new.int32_value_or_default.should eq(0)
      SpecTest::Editions::EditionsMessage.new.explicit_value_or_default.should eq(0)
    end
  end

  describe "closed enums" do
    it "keeps known values" do
      data = hexbytes("0801 1005 1a02 0001 2204 0801 1005 2805 3001")
      message = P2::Closedness.from_protobuf(data)
      message.single.should eq(Closed::CLOSED_ONE)
      message.list.should eq([Closed::CLOSED_FIVE])
      message.packed_list.should eq([Closed::CLOSED_ZERO, Closed::CLOSED_ONE])
      message.by_key.should eq({1 => Closed::CLOSED_FIVE})
      message.in_oneof.should eq(Closed::CLOSED_ONE)
      message.unknown_fields.should be_empty
    end

    it "moves unknown values of singular fields to the unknown fields" do
      message = P2::Closedness.from_protobuf(hexbytes("0801 0807"))
      message.single.should eq(Closed::CLOSED_ONE)
      message.unknown_fields.should eq(hexbytes("0807"))
      message.to_protobuf.should eq(hexbytes("0801 0807"))
      P2::Closedness.from_protobuf(hexbytes("3002")).in_oneof.should be_nil
    end

    it "moves unknown values of repeated fields to the unknown fields" do
      message = P2::Closedness.from_protobuf(hexbytes("1001 1009 1005"))
      message.list.should eq([Closed::CLOSED_ONE, Closed::CLOSED_FIVE])
      message.unknown_fields.should eq(hexbytes("1009"))
    end

    it "moves unknown values of packed fields to the unknown fields as varints" do
      message = P2::Closedness.from_protobuf(hexbytes("1a07 01 09 ffffffff0f"))
      message.packed_list.should eq([Closed::CLOSED_ONE])
      message.unknown_fields.should eq(hexbytes("1809 18ffffffffffffffffff01"))
    end

    it "moves map entries with unknown values to the unknown fields" do
      entry = hexbytes("2204 0801 1009")
      message = P2::Closedness.from_protobuf(entry)
      message.by_key.should be_empty
      message.unknown_fields.should eq(entry)
      # A missing value is the enum's first value, which is known.
      P2::Closedness.from_protobuf(hexbytes("2202 0801")).by_key.should eq({1 => Closed::CLOSED_ZERO})
    end

    it "keeps unknown values of open enums in the field" do
      message = SpecTest::Outer.from_protobuf(hexbytes("1807"))
      message.kind.should eq(SpecTest::Outer::Kind.new(7))
      message.unknown_fields.should be_empty
    end
  end

  describe "required fields" do
    it "reports missing required fields recursively" do
      message = P2::Requirements.new(child: P2::Requirements.new,
        children: [P2::Requirements.new(a: 1), P2::Requirements.new],
        by_name: {"x" => P2::Requirements.new})
      message.missing_required_fields.should eq(["a", "child.a", "children[1].a", "by_name[x].a"])
      message.required_fields_set?.should be_false
      P2::Requirements.new(a: 0).required_fields_set?.should be_true
    end

    it "includes extensions" do
      message = P2::Requirements.new(a: 1)
      message.set_extension(P2::REQUIRED_EXT, P2::Requirements.new)
      message.missing_required_fields.should eq(["(spec_test.proto2.required_ext).a"])
    end

    it "checks required fields on request" do
      expect_raises(Protobuf::RequiredFieldsError, /spec_test.proto2.Requirements is missing required fields: a/) do
        P2::Requirements.new.check_required_fields!
      end
      P2::Requirements.from_protobuf(Bytes.empty).a.should be_nil
      error = expect_raises(Protobuf::RequiredFieldsError) do
        P2::Requirements.from_protobuf(hexbytes("1200"), check_required: true)
      end
      error.fields.should eq(["a", "child.a"])
      P2::Requirements.from_protobuf(hexbytes("0801"), check_required: true).a.should eq(1)
    end

    it "serializes required fields set to their default" do
      P2::Requirements.new(a: 0).to_protobuf.should eq(hexbytes("0800"))
    end

    it "supports editions LEGACY_REQUIRED" do
      SpecTest::Editions::EditionsMessage.new.missing_required_fields.should eq(["required_value"])
    end
  end

  describe "extensions" do
    it "sets, gets, clears and serializes extensions" do
      message = P2::Requirements.new(a: 1)
      message.get_extension(P2::TEXT_EXT).should be_nil
      message.has_extension?(P2::TEXT_EXT).should be_false
      message.set_extension(P2::TEXT_EXT, "hi")
      message.set_extension(P2::PACKED_EXT, [-1, 2])
      message.get_extension(P2::TEXT_EXT).should eq("hi")
      message.has_extension?(P2::TEXT_EXT).should be_true
      message.extension_fields.map(&.full_name).should eq(["spec_test.proto2.packed_ext", "spec_test.proto2.text_ext"])
      message.to_protobuf.should eq(hexbytes("0801 aa0602 0104 c20602 6869"))
      message.clear_extension(P2::TEXT_EXT)
      message.has_extension?(P2::TEXT_EXT).should be_false
      message.to_protobuf.should eq(hexbytes("0801 aa0602 0104"))
    end

    it "parses registered extensions and round trips them" do
      data = hexbytes("0801 a20602 0802 a80601 a80602 c2060161 cb06 d00607 cc06")
      message = P2::Requirements.from_protobuf(data)
      message.unknown_fields.should be_empty
      message.get_extension(P2::REQUIRED_EXT).should eq(P2::Requirements.new(a: 2))
      message.get_extension(P2::PACKED_EXT).should eq([-1, 1])
      message.get_extension(P2::TEXT_EXT).should eq("a")
      message.get_extension(P2::GROUPEXT).should eq([P2::GroupExt.new(g: 7)])
      P2::Requirements.from_protobuf(message.to_protobuf).should eq(message)
      message.clone.should eq(message)
    end

    it "merges repeated occurrences" do
      message = P2::Requirements.from_protobuf(hexbytes("a20602 0802 a20604 1202 0801 aa0601 02 a80603"))
      message.get_extension(P2::REQUIRED_EXT).should eq(P2::Requirements.new(a: 2, child: P2::Requirements.new(a: 1)))
      message.get_extension(P2::PACKED_EXT).should eq([1, -2])
    end

    it "keeps closed enum extensions with unknown values as unknown fields" do
      message = P2::Requirements.from_protobuf(hexbytes("b00601 b00609 b80605 b80607"))
      message.get_extension(P2::CLOSED_EXT).should eq(Closed::CLOSED_ONE)
      message.get_extension(P2::CLOSED_LIST_EXT).should eq([Closed::CLOSED_FIVE])
      message.unknown_fields.should eq(hexbytes("b00609 b80607"))
    end

    it "keeps extensions with the wrong wire type as unknown fields" do
      message = P2::Requirements.from_protobuf(hexbytes("c00605"))
      message.unknown_fields.should eq(hexbytes("c00605"))
      message.get_extension(P2::TEXT_EXT).should be_nil
    end

    it "parses unregistered extensions lazily from the unknown fields" do
      message = DslHost.from_protobuf(hexbytes("0801 a20602 6869 a80601 a80602"))
      message.unknown_fields.should eq(hexbytes("a20602 6869 a80601 a80602"))
      message.get_extension(DSL_NOTE).should eq("hi")
      message.get_extension(DSL_SCORE).should eq([-1_i64, 1_i64])
      message.unknown_fields.should be_empty
      message.to_protobuf.should eq(hexbytes("0801 a20602 6869 aa0602 0102"))
    end

    it "parses extensions registered by hand" do
      ext = Protobuf::Extension(DslHost, Int32).new("dsl.registered", 150)
      Protobuf::Registry.register_extension(ext)
      DslHost.from_protobuf(hexbytes("b00905")).get_extension(ext).should eq(5)
      Protobuf::Registry.extension("dsl.registered").should be(ext)
      Protobuf::Registry.extension("dsl.Host", 150).should be(ext)
    end

    it "compares and clones extensions" do
      a = DslHost.new(id: 1)
      b = DslHost.new(id: 1)
      a.set_extension(DSL_NOTE, "x")
      a.should_not eq(b)
      b.set_extension(DSL_NOTE, "x")
      a.should eq(b)
      copy = a.clone
      copy.should eq(a)
      copy.set_extension(DSL_NOTE, "y")
      a.get_extension(DSL_NOTE).should eq("x")
    end

    it "rejects extensions of other messages at compile time" do
      ok, output = compile_snippet(<<-CRYSTAL)
        require "./src/protobuf"
        class A
          include Protobuf::Message
          field x : Int32, 1
        end
        class B
          include Protobuf::Message
          field x : Int32, 1
        end
        EXT = Protobuf::Extension(A, Int32).new("a.ext", 100)
        B.new.get_extension(EXT)
        CRYSTAL
      ok.should be_false
      output.should contain("A extensions cannot be used with B")
    end

    it "parses the extensions of the conformance messages" do
      message = TestP2.new
      message.set_extension(ProtobufTestMessages::Proto2::EXTENSION_INT32, 3)
      message.set_extension(ProtobufTestMessages::Proto2::GROUPFIELD, ProtobufTestMessages::Proto2::GroupField.new(group_int32: 2))
      TestP2.from_protobuf(message.to_protobuf).should eq(message)
    end
  end

  describe "MessageSet" do
    it "encodes extensions as items and decodes them" do
      set = TestP2::MessageSetCorrect.new
      set.set_extension(TestP2::MessageSetCorrectExtension1::MESSAGE_SET_EXTENSION, TestP2::MessageSetCorrectExtension1.new(str: "a"))
      bytes = set.to_protobuf
      # group 1 { type_id (2) = 1547769, message (3) = { str = "a" } }
      bytes.should eq(hexbytes("0b 10f9bb5e 1a04 ca010161 0c"))
      TestP2::MessageSetCorrect.from_protobuf(bytes).should eq(set)
    end

    it "accepts items with the message before the type id" do
      set = TestP2::MessageSetCorrect.from_protobuf(hexbytes("0b 1a04 ca010161 10f9bb5e 0c"))
      set.get_extension(TestP2::MessageSetCorrectExtension1::MESSAGE_SET_EXTENSION).should eq(TestP2::MessageSetCorrectExtension1.new(str: "a"))
    end

    it "accepts extensions encoded as regular fields" do
      set = TestP2::MessageSetCorrect.from_protobuf(hexbytes("cadff305 04 ca010161"))
      set.get_extension(TestP2::MessageSetCorrectExtension1::MESSAGE_SET_EXTENSION).should eq(TestP2::MessageSetCorrectExtension1.new(str: "a"))
    end

    it "keeps items of unknown extensions without parsing them" do
      item = hexbytes("0b 1005 1a02 0000 0c") # type_id 5, payload with field 0
      set = TestP2::MessageSetCorrect.from_protobuf(item)
      set.unknown_fields.should eq(item)
      set.to_protobuf.should eq(item)
    end

    it "rejects malformed items" do
      expect_raises(Protobuf::DecodeError) { TestP2::MessageSetCorrect.from_protobuf(hexbytes("0b 1005")) }
      expect_raises(Protobuf::DecodeError) { TestP2::MessageSetCorrect.from_protobuf(hexbytes("0b 1005 14")) }
    end
  end
end

private def compile_snippet(source : String) : {Bool, String}
  path = File.join(ProtobufSpec::ROOT, "tmp", "proto2_spec_#{Process.pid}_#{Random.new.hex(4)}.cr")
  File.write(path, source.gsub(%(require "./src/protobuf"), %(require "../src/protobuf")))
  output = IO::Memory.new
  status = Process.run("crystal", ["build", "--no-codegen", "--no-color", path], output: output, error: output, chdir: ProtobufSpec::ROOT)
  {status.success?, output.to_s}
ensure
  File.delete?(path) if path
end
