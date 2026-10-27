require "../../src/grpc"
require "./generated/src/proto/grpc/testing/test_grpc.pb"

module Interop
  alias Testing = Grpc::Testing

  # Implementation of grpc.testing.TestService following the interop test
  # descriptions.
  class TestServiceImpl < Testing::TestService::Service
    ECHO_INITIAL  = "x-grpc-test-echo-initial"
    ECHO_TRAILING = "x-grpc-test-echo-trailing-bin"

    def empty_call(request, context)
      echo_metadata(context)
      Testing::Empty.new
    end

    def unary_call(request, context)
      echo_metadata(context)
      check_compression(request.expect_compressed, context)
      if status = request.response_status
        raise_status(status) unless status.code == 0
      end
      context.compression = "gzip" if request.response_compressed.try(&.value)
      Testing::SimpleResponse.new(payload: payload(request.response_size))
    end

    def cacheable_unary_call(request, context)
      unary_call(request, context)
    end

    def streaming_output_call(request, responses, context)
      echo_metadata(context)
      request.response_parameters.each do |params|
        sleep params.interval_us.microseconds if params.interval_us > 0
        context.compression = params.compressed.try(&.value) ? "gzip" : nil
        responses.send(Testing::StreamingOutputCallResponse.new(payload: payload(params.size)))
      end
      if status = request.response_status
        raise_status(status) unless status.code == 0
      end
    end

    def streaming_input_call(requests, context)
      echo_metadata(context)
      total = 0
      requests.each do |request|
        check_compression(request.expect_compressed, context)
        total += request.payload.try(&.body.size) || 0
      end
      Testing::StreamingInputCallResponse.new(aggregated_payload_size: total)
    end

    def full_duplex_call(requests, responses, context)
      echo_metadata(context)
      requests.each do |request|
        if status = request.response_status
          raise_status(status) unless status.code == 0
        end
        request.response_parameters.each do |params|
          sleep params.interval_us.microseconds if params.interval_us > 0
          context.compression = params.compressed.try(&.value) ? "gzip" : nil
          responses.send(Testing::StreamingOutputCallResponse.new(payload: payload(params.size)))
        end
      end
    end

    def half_duplex_call(requests, responses, context)
      echo_metadata(context)
      buffered = requests.to_a
      buffered.each do |request|
        request.response_parameters.each do |params|
          responses.send(Testing::StreamingOutputCallResponse.new(payload: payload(params.size)))
        end
      end
    end

    def unimplemented_call(request, context)
      raise GRPC::Error.new(:unimplemented, "UnimplementedCall is not implemented")
    end

    private def payload(size : Int32) : Testing::Payload
      Testing::Payload.new(type: Testing::PayloadType::COMPRESSABLE, body: Bytes.new(size))
    end

    private def raise_status(status : Testing::EchoStatus) : NoReturn
      code = GRPC::StatusCode.from_value?(status.code) || GRPC::StatusCode::Unknown
      raise GRPC::Error.new(code, status.message)
    end

    private def check_compression(expect : Testing::BoolValue?, context) : Nil
      if expect.try(&.value) && !context.request_compressed?
        raise GRPC::Error.new(:invalid_argument, "Expected a compressed request message")
      end
    end

    private def echo_metadata(context) : Nil
      if value = context.metadata[ECHO_INITIAL]?
        context.response_metadata[ECHO_INITIAL] = value
      end
      if value = context.metadata[ECHO_TRAILING]?
        context.trailers[ECHO_TRAILING] = value
      end
    end
  end
end
