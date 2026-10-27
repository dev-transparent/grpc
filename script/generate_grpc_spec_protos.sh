#!/bin/sh
# Regenerates the Crystal code for the gRPC spec protos in spec/grpc/proto
# into spec/grpc/generated.
set -e
cd "$(dirname "$0")/.."

mkdir -p bin spec/grpc/generated
crystal build src/protoc-gen-crystal.cr -o bin/protoc-gen-crystal
protoc --plugin=protoc-gen-crystal=bin/protoc-gen-crystal --crystal_out=spec/grpc/generated -Ispec/grpc/proto \
  spec/grpc/proto/*.proto
