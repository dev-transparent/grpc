#!/bin/sh
# Long randomized fuzzing campaigns for the protobuf runtime:
#
#   binary  the binary decoder on mutated conformance messages (decode must
#           raise Protobuf::DecodeError or re-encode stably; JSON printed
#           from decoded messages must re-parse)
#   json    the JSON parser and printer on mutated JSON documents
#   proto   the .proto tokenizer, parser, importer and generator on mutated
#           sources (only ParseError may be raised)
#   python  differential decoding against Python's protobuf (upb)
#
# Usage: script/fuzz_protobuf.sh [SECONDS_PER_TARGET] [TARGET...]
# Environment: SEED (random by default), PYTHON (interpreter with protobuf
# and grpcio-tools for the python target).
# Failing inputs are written to tmp/fuzz/protobuf.
set -e
cd "$(dirname "$0")/.."
SECONDS_PER_TARGET="${1:-150}"
[ $# -gt 0 ] && shift
mkdir -p bin
crystal build --release spec/fuzz/protobuf_fuzz.cr -o bin/protobuf_fuzz
ARGS="--seconds $SECONDS_PER_TARGET"
[ -n "$SEED" ] && ARGS="$ARGS --seed $SEED"
exec ./bin/protobuf_fuzz $ARGS "$@"
