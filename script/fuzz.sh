#!/bin/sh
# Runs a randomized fuzz campaign against the HTTP/2 layer.
#
#   script/fuzz.sh [target] [iterations|duration] [seed]
#
#   target      frame, hpack, server, client or all (default: all)
#   budget      iteration count per target (e.g. 20000) or total duration
#               with a unit (e.g. 600s, 10m); default 10m
#   seed        random seed (default: random)
#
#   script/fuzz.sh replay tmp/fuzz/crashes/server-0123456789abcdef.bin
#
# Failing inputs are saved to tmp/fuzz/crashes/ (an input and a .txt file
# with the failure). The binary is built with execution contexts so that a
# watchdog can abort (and save) inputs that hang.
set -e
cd "$(dirname "$0")/.."
mkdir -p bin tmp/fuzz/crashes
crystal build --release -Dpreview_mt -Dexecution_context spec/fuzz/http2_fuzz.cr -o bin/http2_fuzz
if [ "$1" = "replay" ]; then
  shift
  exec ./bin/http2_fuzz replay "$@"
fi
exec ./bin/http2_fuzz "${1:-all}" "${2:-10m}" ${3:-} tmp/fuzz/crashes
