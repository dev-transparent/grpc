#!/bin/sh
# Regenerates the Crystal code for the protobuf spec protos
# (spec/protobuf/proto -> spec/protobuf/generated) using protoc-gen-crystal.
set -e
cd "$(dirname "$0")/.."
INCLUDE="${PROTOC_INCLUDE:-$(dirname "$(dirname "$(command -v protoc)")")/include}"
mkdir -p bin
crystal build src/protoc-gen-crystal.cr -o bin/protoc-gen-crystal
rm -rf spec/protobuf/generated
mkdir -p spec/protobuf/generated
protoc --plugin=protoc-gen-crystal=bin/protoc-gen-crystal \
  --crystal_out=grpc=false,experimental_editions=true:spec/protobuf/generated \
  -Ispec/protobuf/proto -I"$INCLUDE" \
  google/protobuf/test_messages_proto3.proto \
  google/protobuf/test_messages_proto2.proto \
  spec_test/types.proto \
  spec_test/sub/imported.proto \
  spec_test/editions.proto \
  spec_test/editions_implicit.proto \
  spec_test/proto2.proto \
  spec_test/service.proto \
  conformance/conformance.proto \
  conformance/test_protos/test_messages_edition2023.proto \
  conformance/test_protos/test_messages_edition_unstable.proto \
  editions/golden/test_messages_proto2_editions.proto \
  editions/golden/test_messages_proto3_editions.proto
