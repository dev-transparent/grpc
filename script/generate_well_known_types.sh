#!/bin/sh
# Regenerates the descriptor, plugin and well-known type messages bundled with
# the protobuf runtime using protoc-gen-crystal itself.
set -e
cd "$(dirname "$0")/.."
INCLUDE="${PROTOC_INCLUDE:-$(dirname "$(dirname "$(command -v protoc)")")/include}"
crystal build src/protoc-gen-crystal.cr -o bin/protoc-gen-crystal
protoc --plugin=protoc-gen-crystal=bin/protoc-gen-crystal --crystal_out=src/protobuf -I"$INCLUDE" \
  google/protobuf/descriptor.proto \
  google/protobuf/compiler/plugin.proto \
  google/protobuf/any.proto \
  google/protobuf/api.proto \
  google/protobuf/duration.proto \
  google/protobuf/empty.proto \
  google/protobuf/field_mask.proto \
  google/protobuf/source_context.proto \
  google/protobuf/struct.proto \
  google/protobuf/timestamp.proto \
  google/protobuf/type.proto \
  google/protobuf/wrappers.proto
