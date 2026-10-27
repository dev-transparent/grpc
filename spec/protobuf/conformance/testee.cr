# Conformance testee for protobuf's official conformance suite
# (`conformance_test_runner`, see script/conformance.sh).
#
# The runner writes requests to stdin and reads responses from stdout, each
# framed with a 4-byte little-endian length and encoded as
# `conformance.ConformanceRequest` / `conformance.ConformanceResponse`.
# Binary and JSON payloads are supported; text format and JSPB requests are
# reported as skipped.
require "../../../src/protobuf"
require "../generated/conformance/conformance.pb"
require "../generated/google/protobuf/test_messages_proto3.pb"
require "../generated/google/protobuf/test_messages_proto2.pb"
require "../generated/conformance/test_protos/test_messages_edition2023.pb"
require "../generated/conformance/test_protos/test_messages_edition_unstable.pb"
require "../generated/editions/golden/test_messages_proto2_editions.pb"
require "../generated/editions/golden/test_messages_proto3_editions.pb"

module ConformanceTestee
  alias Request = Conformance::ConformanceRequest
  alias Response = Conformance::ConformanceResponse

  # Handles one request. Never raises: unexpected errors are reported as
  # runtime errors.
  def self.handle(request : Request) : Response
    if request.message_type == "conformance.FailureSet"
      # The runner asks which tests are expected to fail; the failure list
      # is given to the runner instead.
      return Response.new(protobuf_payload: Conformance::FailureSet.new.to_protobuf)
    end

    klass = Protobuf::Registry.message_class?(request.message_type)
    return Response.new(runtime_error: "Unknown message type #{request.message_type}") unless klass

    message = begin
      if bytes = request.protobuf_payload
        klass.from_protobuf(bytes)
      elsif json = request.json_payload
        ignore = request.test_category.json_ignore_unknown_parsing_test?
        klass.from_json(json, Protobuf::JSON::ParseOptions.new(ignore_unknown_fields: ignore))
      else
        return Response.new(skipped: "Only binary and JSON payloads are supported")
      end
    rescue ex : Protobuf::DecodeError | Protobuf::JSON::ParseError
      return Response.new(parse_error: ex.message || ex.class.name)
    end

    case request.requested_output_format
    when .protobuf?
      Response.new(protobuf_payload: message.to_protobuf)
    when .json?
      begin
        Response.new(json_payload: message.to_json(Protobuf::JSON::PrintOptions.new))
      rescue ex : Protobuf::JSON::SerializeError
        Response.new(serialize_error: ex.message || ex.class.name)
      end
    else
      Response.new(skipped: "Only binary and JSON output are supported")
    end
  rescue ex
    Response.new(runtime_error: "#{ex.class}: #{ex.message}")
  end

  def self.run(input : IO, output : IO) : Nil
    loop do
      length = begin
        input.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      rescue IO::EOFError
        break
      end
      data = Bytes.new(length)
      input.read_fully(data)
      response = handle(Request.from_protobuf(data))
      bytes = response.to_protobuf
      output.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
      output.write(bytes)
      output.flush
    end
  end
end

ConformanceTestee.run(STDIN, STDOUT)
