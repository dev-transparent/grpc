require "../grpc"
require "./reflection/grpc/reflection/v1/reflection_grpc.pb"
require "./reflection/grpc/reflection/v1alpha/reflection_grpc.pb"

module GRPC
  # The gRPC server reflection service (`grpc.reflection.v1` and the older
  # `grpc.reflection.v1alpha`), which lets tools such as `grpcurl`, `grpcui`
  # and Postman discover a server's services and message types at runtime.
  #
  # ```
  # require "grpc/reflection"
  #
  # server = GRPC::Server.new
  # server.handle(Greeter.new)
  # GRPC::Reflection.enable(server)
  # ```
  #
  # Descriptors come from `Protobuf::Registry`, which every generated file
  # (from `protoc-gen-crystal` or `import_proto`) populates.
  module Reflection
    alias V1 = ::Grpc::Reflection::V1
    alias V1Alpha = ::Grpc::Reflection::V1alpha

    # Registers both versions of the reflection service on *server*.
    def self.enable(server : Server) : Nil
      core = Core.new(server)
      server.handle(Service.new(core))
      server.handle(AlphaService.new(core))
    end

    # Shared implementation, speaking the v1 messages.
    class Core
      def initialize(@server : Server)
      end

      # Answers one request. *sent* holds the files already sent on this
      # stream: like other implementations, each file descriptor is sent at
      # most once per stream so clients are not flooded with dependencies.
      def answer(request : V1::ServerReflectionRequest, sent : Set(String)) : V1::ServerReflectionResponse
        response = V1::ServerReflectionResponse.new(valid_host: request.host, original_request: request)
        case request.message_request_case
        when :list_services
          names = @server.services.map(&.service_name).uniq!.sort!
          response.list_services_response = V1::ListServiceResponse.new(
            service: names.map { |name| V1::ServiceResponse.new(name: name) })
        when :file_by_filename
          name = request.file_by_filename.not_nil!
          if Protobuf::Registry.file?(name)
            response.file_descriptor_response = files(name, sent)
          else
            response.error_response = not_found("File not found: #{name}")
          end
        when :file_containing_symbol
          symbol = request.file_containing_symbol.not_nil!.lchop('.')
          if file = Protobuf::Registry.file_name_containing_symbol(symbol)
            response.file_descriptor_response = files(file, sent)
          else
            response.error_response = not_found("Symbol not found: #{symbol}")
          end
        when :file_containing_extension
          extension = request.file_containing_extension.not_nil!
          type = extension.containing_type.lchop('.')
          if file = Protobuf::Registry.file_containing_extension(type, extension.extension_number)
            response.file_descriptor_response = files(file.name.not_nil!, sent)
          else
            response.error_response = not_found("Extension not found: #{type}(#{extension.extension_number})")
          end
        when :all_extension_numbers_of_type
          type = request.all_extension_numbers_of_type.not_nil!.lchop('.')
          if Protobuf::Registry.message_descriptor(type)
            response.all_extension_numbers_response = V1::ExtensionNumberResponse.new(
              base_type_name: type, extension_number: Protobuf::Registry.extension_numbers(type).sort)
          else
            response.error_response = not_found("Type not found: #{type}")
          end
        else
          response.error_response = V1::ErrorResponse.new(
            error_code: StatusCode::InvalidArgument.value, error_message: "Empty or unknown reflection request")
        end
        response
      end

      private def files(name : String, sent : Set(String)) : V1::FileDescriptorResponse
        result = V1::FileDescriptorResponse.new
        Protobuf::Registry.file_with_dependencies(name).each_with_index do |file, index|
          file_name = file.name.not_nil!
          # The requested file is always sent; dependencies only once.
          next if index > 0 && sent.includes?(file_name)
          sent << file_name
          bytes = Protobuf::Registry.file_descriptor_bytes(file_name) || file.to_protobuf
          result.file_descriptor_proto << bytes
        end
        result
      end

      private def not_found(message : String) : V1::ErrorResponse
        V1::ErrorResponse.new(error_code: StatusCode::NotFound.value, error_message: message)
      end
    end

    # `grpc.reflection.v1.ServerReflection`.
    class Service < V1::ServerReflection::Service
      def initialize(@core : Core)
      end

      def server_reflection_info(requests, responses, context)
        sent = Set(String).new
        requests.each { |request| responses << @core.answer(request, sent) }
      end
    end

    # `grpc.reflection.v1alpha.ServerReflection`; its messages are
    # wire-compatible with v1, so requests are transcoded.
    class AlphaService < V1Alpha::ServerReflection::Service
      def initialize(@core : Core)
      end

      def server_reflection_info(requests, responses, context)
        sent = Set(String).new
        requests.each do |request|
          answer = @core.answer(V1::ServerReflectionRequest.from_protobuf(request.to_protobuf), sent)
          responses << V1Alpha::ServerReflectionResponse.from_protobuf(answer.to_protobuf)
        end
      end
    end
  end
end
