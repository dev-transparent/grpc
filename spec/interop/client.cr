# gRPC interop test client running the standard test cases from
# https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md
#
#   crystal run spec/interop/client.cr -- --server_port=10000 [--test_case=large_unary]
#
# Exits with a non-zero status if any test case fails.
require "option_parser"
require "./service"

module Interop
  class TestFailure < Exception
  end

  class Client
    alias Testing = Grpc::Testing

    TEST_CASES = %w(
      empty_unary large_unary client_compressed_unary compressed_request server_compressed_unary
      client_streaming server_streaming server_compressed_streaming ping_pong
      empty_stream custom_metadata status_code_and_message special_status_message
      unimplemented_method unimplemented_service cancel_after_begin
      cancel_after_first_response timeout_on_sleeping_server
    )

    def initialize(@target : String, credentials : GRPC::ChannelCredentials = GRPC::ChannelCredentials.insecure)
      @channel = GRPC::Channel.new(@target, credentials: credentials)
      @stub = Testing::TestService::Client.new(@channel)
    end

    def run(test_case : String) : Nil
      {% begin %}
        case test_case
        {% for name in TEST_CASES %}
          when {{name}} then {{name.id}}
        {% end %}
        else
          raise ArgumentError.new("Unknown test case #{test_case}")
        end
      {% end %}
    end

    def empty_unary
      response = @stub.empty_call(Testing::Empty.new)
      assert response == Testing::Empty.new, "unexpected response"
    end

    def large_unary
      response = @stub.unary_call(Testing::SimpleRequest.new(
        response_type: Testing::PayloadType::COMPRESSABLE,
        response_size: 314_159,
        payload: payload(271_828)))
      assert response.payload.try(&.body.size) == 314_159, "wrong payload size"
      assert response.payload.try(&.body.all?(&.zero?)), "payload not zeroed"
    end

    def client_compressed_unary
      # Probe: the server must reject an uncompressed message it expected to
      # be compressed.
      expect_status(GRPC::StatusCode::InvalidArgument) do
        @stub.unary_call(Testing::SimpleRequest.new(
          expect_compressed: Testing::BoolValue.new(value: true),
          response_size: 314_159, payload: payload(271_828)))
      end
      compressed = Testing::TestService::Client.new(@channel, compression: "gzip")
      response = compressed.unary_call(Testing::SimpleRequest.new(
        expect_compressed: Testing::BoolValue.new(value: true),
        response_size: 314_159, payload: payload(271_828)))
      assert response.payload.try(&.body.size) == 314_159, "wrong payload size (compressed)"
      response = @stub.unary_call(Testing::SimpleRequest.new(
        expect_compressed: Testing::BoolValue.new(value: false),
        response_size: 314_159, payload: payload(271_828)))
      assert response.payload.try(&.body.size) == 314_159, "wrong payload size (uncompressed)"
    end

    # Sends gzip compressed requests (unary and streaming) without the
    # feature probe, for servers that do not implement expect_compressed.
    def compressed_request
      compressed = Testing::TestService::Client.new(@channel, compression: "gzip")
      response = compressed.unary_call(Testing::SimpleRequest.new(response_size: 314_159, payload: payload(271_828)))
      assert response.payload.try(&.body.size) == 314_159, "wrong payload size"
      response = compressed.streaming_input_call do |call|
        [27_182, 45_904].each { |size| call << Testing::StreamingInputCallRequest.new(payload: payload(size)) }
      end
      assert response.aggregated_payload_size == 73_086, "wrong aggregated size"
    end

    def server_compressed_unary
      [true, false].each do |compressed|
        response = @stub.unary_call(Testing::SimpleRequest.new(
          response_compressed: Testing::BoolValue.new(value: compressed),
          response_size: 314_159, payload: payload(271_828)))
        assert response.payload.try(&.body.size) == 314_159, "wrong payload size"
      end
    end

    def client_streaming
      response = @stub.streaming_input_call do |call|
        [27_182, 8, 1_828, 45_904].each do |size|
          call << Testing::StreamingInputCallRequest.new(payload: payload(size))
        end
      end
      assert response.aggregated_payload_size == 74_922, "wrong aggregated size #{response.aggregated_payload_size}"
    end

    def server_streaming
      sizes = [31_415, 9, 2_653, 58_979]
      request = Testing::StreamingOutputCallRequest.new(
        response_parameters: sizes.map { |size| Testing::ResponseParameters.new(size: size) })
      received = @stub.streaming_output_call(request).map { |response| response.payload.try(&.body.size) }.to_a
      assert received == sizes, "wrong response sizes #{received}"
    end

    def server_compressed_streaming
      request = Testing::StreamingOutputCallRequest.new(response_parameters: [
        Testing::ResponseParameters.new(size: 31_415, compressed: Testing::BoolValue.new(value: true)),
        Testing::ResponseParameters.new(size: 92_653, compressed: Testing::BoolValue.new(value: false)),
      ])
      received = @stub.streaming_output_call(request).map { |response| response.payload.try(&.body.size) }.to_a
      assert received == [31_415, 92_653], "wrong response sizes #{received}"
    end

    def ping_pong
      call = @stub.full_duplex_call
      [{27_182, 31_415}, {8, 9}, {1_828, 2_653}, {45_904, 58_979}].each do |(request_size, response_size)|
        call.send(Testing::StreamingOutputCallRequest.new(
          response_parameters: [Testing::ResponseParameters.new(size: response_size)],
          payload: payload(request_size)))
        response = call.receive? || raise TestFailure.new("stream ended early")
        assert response.payload.try(&.body.size) == response_size, "wrong response size"
      end
      call.close_send
      assert call.receive?.nil?, "expected end of stream"
    end

    def empty_stream
      call = @stub.full_duplex_call
      call.close_send
      assert call.receive?.nil?, "expected no responses"
    end

    def custom_metadata
      initial_value = "test_initial_metadata_value"
      trailing_value = String.new(Bytes[0xab, 0xab, 0xab])
      metadata = GRPC::Metadata.new
      metadata["x-grpc-test-echo-initial"] = initial_value
      metadata["x-grpc-test-echo-trailing-bin"] = trailing_value

      call = @stub.unary_call_call(Testing::SimpleRequest.new(response_size: 314_159, payload: payload(271_828)), metadata: metadata)
      call.response
      assert call.headers["x-grpc-test-echo-initial"]? == initial_value, "initial metadata not echoed (unary): #{call.headers.inspect}"
      assert call.trailers["x-grpc-test-echo-trailing-bin"]? == trailing_value, "trailing metadata not echoed (unary): #{call.trailers.inspect}"

      stream = @stub.full_duplex_call(metadata: metadata)
      stream.send(Testing::StreamingOutputCallRequest.new(
        response_parameters: [Testing::ResponseParameters.new(size: 314_159)], payload: payload(271_828)))
      stream.close_send
      stream.to_a
      assert stream.headers["x-grpc-test-echo-initial"]? == initial_value, "initial metadata not echoed (stream)"
      assert stream.trailers["x-grpc-test-echo-trailing-bin"]? == trailing_value, "trailing metadata not echoed (stream)"
    end

    def status_code_and_message
      status = Testing::EchoStatus.new(code: 2, message: "test status message")
      error = expect_status(GRPC::StatusCode::Unknown) do
        @stub.unary_call(Testing::SimpleRequest.new(response_status: status))
      end
      assert error.status.message == "test status message", "wrong message #{error.status.message.inspect}"

      error = expect_status(GRPC::StatusCode::Unknown) do
        call = @stub.full_duplex_call
        call.send(Testing::StreamingOutputCallRequest.new(response_status: status))
        call.close_send
        call.to_a
      end
      assert error.status.message == "test status message", "wrong message #{error.status.message.inspect}"
    end

    def special_status_message
      message = "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
      error = expect_status(GRPC::StatusCode::Unknown) do
        @stub.unary_call(Testing::SimpleRequest.new(response_status: Testing::EchoStatus.new(code: 2, message: message)))
      end
      assert error.status.message == message, "wrong message #{error.status.message.inspect}"
    end

    def unimplemented_method
      expect_status(GRPC::StatusCode::Unimplemented) do
        @stub.unimplemented_call(Testing::Empty.new)
      end
    end

    def unimplemented_service
      stub = Testing::UnimplementedService::Client.new(@channel)
      expect_status(GRPC::StatusCode::Unimplemented) do
        stub.unimplemented_call(Testing::Empty.new)
      end
    end

    def cancel_after_begin
      call = @stub.streaming_input_call
      call.cancel
      expect_status(GRPC::StatusCode::Cancelled) { call.close_and_receive }
    end

    def cancel_after_first_response
      call = @stub.full_duplex_call
      call.send(Testing::StreamingOutputCallRequest.new(
        response_parameters: [Testing::ResponseParameters.new(size: 31_415)], payload: payload(27_182)))
      call.receive? || raise TestFailure.new("no response")
      call.cancel
      expect_status(GRPC::StatusCode::Cancelled) { call.receive? }
    end

    def timeout_on_sleeping_server
      expect_status(GRPC::StatusCode::DeadlineExceeded) do
        call = @stub.full_duplex_call(deadline: 1.millisecond)
        call.send(Testing::StreamingOutputCallRequest.new(payload: payload(27_182)))
        call.receive?
      end
    end

    private def payload(size : Int32) : Testing::Payload
      Testing::Payload.new(type: Testing::PayloadType::COMPRESSABLE, body: Bytes.new(size))
    end

    private def assert(condition, message : String) : Nil
      raise TestFailure.new(message) unless condition
    end

    private def expect_status(code : GRPC::StatusCode, &) : GRPC::Error
      yield
      raise TestFailure.new("expected #{code}, call succeeded")
    rescue e : GRPC::Error
      raise TestFailure.new("expected #{code}, got #{e.code}: #{e.status.message}") unless e.code == code
      e
    end
  end
end

host = "127.0.0.1"
port = 10000
test_case = "all"
use_tls = false
use_test_ca = false
host_override = nil
OptionParser.parse do |parser|
  parser.on("--use_tls=BOOL", "Connect with TLS") { |value| use_tls = value == "true" }
  parser.on("--use_test_ca=BOOL", "Trust the gRPC test CA (spec/interop/certs/ca.pem)") { |value| use_test_ca = value == "true" }
  parser.on("--server_host_override=HOST", "Server name for TLS verification") { |value| host_override = value }
  parser.on("--server_host=HOST", "Server host") { |value| host = value }
  parser.on("--server_port=PORT", "Server port") { |value| port = value.to_i }
  parser.on("--test_case=NAME", "Test case to run (default: all)") { |value| test_case = value }
end

credentials = if use_tls
                ca = use_test_ca ? File.join(__DIR__, "certs", "ca.pem") : nil
                GRPC::ChannelCredentials.tls(ca_file: ca, server_name_override: host_override)
              else
                GRPC::ChannelCredentials.insecure
              end
client = Interop::Client.new("#{host}:#{port}", credentials)
cases = test_case == "all" ? Interop::Client::TEST_CASES : test_case.split(',')
failures = 0
cases.each do |name|
  begin
    client.run(name)
    puts "PASS #{name}"
  rescue e
    failures += 1
    puts "FAIL #{name}: #{e.class}: #{e.message}"
  end
end
puts "#{cases.size - failures}/#{cases.size} interop test cases passed"
exit(failures == 0 ? 0 : 1)
