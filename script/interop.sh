#!/bin/sh
# Runs the gRPC interop test cases:
#
#   1. Crystal client  -> Crystal server
#   2. grpcio client   -> Crystal server   (requires Python grpcio)
#   3. Crystal client  -> grpcio server    (requires Python grpcio)
#   4. grpc-go client  -> Crystal server   (requires grpc-go interop binaries)
#   5. Crystal client  -> grpc-go server   (requires grpc-go interop binaries)
#
# Set PYTHON to an interpreter with grpcio and grpcio-tools installed, e.g.
#   python3 -m venv /tmp/venv && /tmp/venv/bin/pip install grpcio grpcio-tools
#   PYTHON=/tmp/venv/bin/python script/interop.sh
set -e
cd "$(dirname "$0")/.."

PYTHON="${PYTHON:-python3}"
PORT_BASE="${PORT_BASE:-17000}"
INTEROP=spec/interop

mkdir -p bin
crystal build src/protoc-gen-crystal.cr -o bin/protoc-gen-crystal
protoc --plugin=protoc-gen-crystal=bin/protoc-gen-crystal --crystal_out=$INTEROP/generated -I$INTEROP/proto \
  src/proto/grpc/testing/test.proto src/proto/grpc/testing/messages.proto src/proto/grpc/testing/empty.proto
crystal build $INTEROP/server.cr -o bin/interop_server
crystal build $INTEROP/client.cr -o bin/interop_client

PIDS=""
cleanup() {
  for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

wait_for_port() {
  i=0
  while ! nc -z 127.0.0.1 "$1" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -gt 100 ]; then echo "Server on port $1 did not start"; exit 1; fi
    sleep 0.1
  done
}

STATUS=0

echo "== Crystal client -> Crystal server"
./bin/interop_server --port=$PORT_BASE > /dev/null 2>&1 &
PIDS="$PIDS $!"
wait_for_port $PORT_BASE
./bin/interop_client --server_port=$PORT_BASE || STATUS=1

if "$PYTHON" -c "import grpc, grpc_tools" 2>/dev/null; then
  "$PYTHON" -m grpc_tools.protoc -I$INTEROP/proto --python_out=$INTEROP/python --grpc_python_out=$INTEROP/python \
    src/proto/grpc/testing/test.proto src/proto/grpc/testing/messages.proto src/proto/grpc/testing/empty.proto

  echo "== grpcio client -> Crystal server"
  "$PYTHON" $INTEROP/python/interop.py client --port $PORT_BASE || STATUS=1

  echo "== Crystal client -> grpcio server"
  "$PYTHON" $INTEROP/python/interop.py server --port $((PORT_BASE + 1)) > /dev/null 2>&1 &
  PIDS="$PIDS $!"
  wait_for_port $((PORT_BASE + 1))
  # client_compressed_unary relies on the server checking expect_compressed,
  # which the Python reference server does not implement.
  ./bin/interop_client --server_port=$((PORT_BASE + 1)) --test_case=empty_unary,large_unary,compressed_request,server_compressed_unary,client_streaming,server_streaming,server_compressed_streaming,ping_pong,empty_stream,custom_metadata,status_code_and_message,special_status_message,unimplemented_method,unimplemented_service,cancel_after_begin,cancel_after_first_response,timeout_on_sleeping_server || STATUS=1
else
  echo "Python grpcio not available ($PYTHON); skipping cross-implementation tests"
fi

GOBIN="${GOBIN:-$(go env GOPATH 2>/dev/null)/bin}"
if [ -x "$GOBIN/client" ] && [ -x "$GOBIN/server" ]; then
  # Official grpc-go interop binaries:
  #   go install google.golang.org/grpc/interop/client@latest
  #   go install google.golang.org/grpc/interop/server@latest
  echo "== grpc-go client -> Crystal server"
  GO_CASES="empty_unary large_unary client_streaming server_streaming ping_pong empty_stream timeout_on_sleeping_server cancel_after_begin cancel_after_first_response status_code_and_message special_status_message unimplemented_method unimplemented_service custom_metadata rpc_soak channel_soak"
  passed=0; total=0
  for t in $GO_CASES; do
    total=$((total + 1))
    # Soak iterations sometimes exceed the default 1s latency budget because
    # of grpc-go's per-channel setup on some machines (equally against
    # grpc-go's own server), so allow slower iterations.
    if "$GOBIN/client" --server_port=$PORT_BASE --soak_per_iteration_max_acceptable_latency_ms=10000 --test_case=$t > /tmp/grpc_go_interop.log 2>&1; then
      passed=$((passed + 1))
    else
      echo "FAIL $t: $(tail -2 /tmp/grpc_go_interop.log)"; STATUS=1
    fi
  done
  echo "$passed/$total interop test cases passed"

  echo "== Crystal client -> grpc-go server"
  (cd /tmp && exec "$GOBIN/server" --port=$((PORT_BASE + 2))) > /dev/null 2>&1 &
  PIDS="$PIDS $!"
  wait_for_port $((PORT_BASE + 2))
  # The grpc-go interop server does not register gzip, so the compression
  # cases are excluded.
  ./bin/interop_client --server_port=$((PORT_BASE + 2)) --test_case=empty_unary,large_unary,client_streaming,server_streaming,ping_pong,empty_stream,custom_metadata,status_code_and_message,special_status_message,unimplemented_method,unimplemented_service,cancel_after_begin,cancel_after_first_response,timeout_on_sleeping_server || STATUS=1
else
  echo "grpc-go interop binaries not found in $GOBIN; skipping grpc-go tests"
fi

echo "== TLS: Crystal client -> Crystal server"
./bin/interop_server --port=$((PORT_BASE + 10)) --use_tls=true > /dev/null 2>&1 &
PIDS="$PIDS $!"
wait_for_port $((PORT_BASE + 10))
TLS_FLAGS="--use_tls=true --use_test_ca=true --server_host_override=foo.test.google.fr"
./bin/interop_client --server_port=$((PORT_BASE + 10)) $TLS_FLAGS || STATUS=1

if "$PYTHON" -c "import grpc" 2>/dev/null; then
  echo "== TLS: grpcio client -> Crystal server"
  "$PYTHON" $INTEROP/python/interop.py client --port $((PORT_BASE + 10)) --use_tls true || STATUS=1
  echo "== TLS: Crystal client -> grpcio server"
  "$PYTHON" $INTEROP/python/interop.py server --port $((PORT_BASE + 11)) --use_tls true > /dev/null 2>&1 &
  PIDS="$PIDS $!"
  wait_for_port $((PORT_BASE + 11))
  ./bin/interop_client --server_port=$((PORT_BASE + 11)) $TLS_FLAGS --test_case=empty_unary,large_unary,compressed_request,server_compressed_unary,client_streaming,server_streaming,server_compressed_streaming,ping_pong,empty_stream,custom_metadata,status_code_and_message,special_status_message,unimplemented_method,unimplemented_service,cancel_after_begin,cancel_after_first_response,timeout_on_sleeping_server || STATUS=1
fi

if [ -x "$GOBIN/client" ] && [ -x "$GOBIN/server" ]; then
  echo "== TLS: grpc-go client -> Crystal server"
  passed=0; total=0
  for t in $GO_CASES; do
    total=$((total + 1))
    # The first TLS handshake of the grpc-go client can take several seconds
    # on some machines (it fails the 1s soak latency budget against grpc-go's
    # own TLS server too), so allow slower soak iterations here.
    if "$GOBIN/client" --server_port=$((PORT_BASE + 10)) --use_tls=true --use_test_ca=true --server_host_override=foo.test.google.fr --soak_per_iteration_max_acceptable_latency_ms=10000 --test_case=$t > /tmp/grpc_go_interop.log 2>&1; then
      passed=$((passed + 1))
    else
      echo "FAIL $t: $(tail -2 /tmp/grpc_go_interop.log)"; STATUS=1
    fi
  done
  echo "$passed/$total interop test cases passed"

  echo "== TLS: Crystal client -> grpc-go server"
  (cd /tmp && exec "$GOBIN/server" --port=$((PORT_BASE + 12)) --use_tls=true) > /dev/null 2>&1 &
  PIDS="$PIDS $!"
  wait_for_port $((PORT_BASE + 12))
  ./bin/interop_client --server_port=$((PORT_BASE + 12)) $TLS_FLAGS --test_case=empty_unary,large_unary,client_streaming,server_streaming,ping_pong,empty_stream,custom_metadata,status_code_and_message,special_status_message,unimplemented_method,unimplemented_service,cancel_after_begin,cancel_after_first_response,timeout_on_sleeping_server || STATUS=1
fi

exit $STATUS
