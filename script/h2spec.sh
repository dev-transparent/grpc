#!/bin/sh
# Runs the h2spec HTTP/2 conformance suite (https://github.com/summerwind/h2spec)
# against examples/h2spec_server.cr. Extra arguments are passed to h2spec,
# e.g. `script/h2spec.sh -S` for strict mode.
set -e
cd "$(dirname "$0")/.."
PORT="${PORT:-18080}"
command -v h2spec > /dev/null || { echo "h2spec not found (brew install h2spec)"; exit 1; }
mkdir -p bin
crystal build --release examples/h2spec_server.cr -o bin/h2spec_server
./bin/h2spec_server "$PORT" > /dev/null &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT
i=0
while ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
  i=$((i + 1)); [ $i -gt 100 ] && { echo "server did not start"; exit 1; }
  sleep 0.1
done
h2spec -p "$PORT" "$@"
