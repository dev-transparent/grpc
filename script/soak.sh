#!/bin/sh
# Runs the official grpc-go interop client's soak tests against the Crystal
# interop server (spec/interop/server.cr):
#
#   rpc_soak      many RPCs on one channel (exercises BDP pings, flow
#                 control, keepalive enforcement and abuse limits)
#   channel_soak  a new channel (TCP + HTTP/2 connection) per RPC
#
# Requires the grpc-go interop client: go install google.golang.org/grpc/interop/client@latest
#
#   script/soak.sh [rpc_iterations] [channel_iterations] [threads]
#
# Defaults: 20000 rpc_soak and 8000 channel_soak iterations on 16 threads.
# channel_soak is bounded by the client's ephemeral ports: grpc-go closes
# the TCP connection first, so every channel leaves a client side TIME_WAIT
# socket for 2*MSL (30s on macOS, with ~16k ephemeral ports). Larger counts
# fail with "can't assign requested address" against any server, including
# grpc-go's own. SERVER_HOST defaults to 127.0.0.1 because resolving
# "localhost" adds ~60ms per channel on some systems.
set -e
cd "$(dirname "$0")/.."
RPC_ITERATIONS="${1:-20000}"
CHANNEL_ITERATIONS="${2:-8000}"
THREADS="${3:-16}"
PORT="${PORT:-50101}"
HOST="${SERVER_HOST:-127.0.0.1}"
CLIENT="${GRPC_GO_CLIENT:-$(go env GOPATH)/bin/client}"
[ -x "$CLIENT" ] || { echo "grpc-go interop client not found at $CLIENT"; exit 1; }

mkdir -p bin
crystal build --release spec/interop/server.cr -o bin/interop_server
./bin/interop_server --port="$PORT" > /dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT
i=0
while ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
  i=$((i + 1)); [ $i -gt 100 ] && { echo "server did not start"; exit 1; }
  sleep 0.1
done

wait_time_wait() {
  # Let earlier TIME_WAIT sockets expire so ephemeral ports are available.
  while [ "$(netstat -an | grep -c TIME_WAIT)" -gt 1000 ]; do sleep 2; done
}

soak() {
  echo "== $1 ($2 iterations, $THREADS threads)"
  "$CLIENT" --server_host="$HOST" --server_port="$PORT" --test_case="$1" \
    --soak_iterations="$2" --soak_num_threads="$THREADS" --soak_max_failures=0 \
    --soak_overall_timeout_seconds=300 --soak_per_iteration_max_acceptable_latency_ms=1000 2>&1 |
    grep -E "soak test successes|FATAL|failed:" | head -20
}

STATUS=0
wait_time_wait
soak rpc_soak "$RPC_ITERATIONS" | tee /tmp/soak-rpc.$$ ; grep -q "Total failures: 0\." /tmp/soak-rpc.$$ || STATUS=1
wait_time_wait
soak channel_soak "$CHANNEL_ITERATIONS" | tee /tmp/soak-channel.$$ ; grep -q "Total failures: 0\." /tmp/soak-channel.$$ || STATUS=1
rm -f /tmp/soak-rpc.$$ /tmp/soak-channel.$$
[ $STATUS -eq 0 ] && echo "soak tests passed" || echo "soak tests FAILED"
exit $STATUS
