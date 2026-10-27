# protoc plugin generating Crystal code from .proto files.
#
#   crystal build src/protoc-gen-crystal.cr -o bin/protoc-gen-crystal
#   protoc --plugin=bin/protoc-gen-crystal --crystal_out=src/proto foo.proto
require "./protobuf/compiler/generator"

input = STDIN.getb_to_end
request = Google::Protobuf::Compiler::CodeGeneratorRequest.from_protobuf(input)
response = Protobuf::Compiler::Generator.call(request)
STDOUT.write(response.to_protobuf)
STDOUT.flush
