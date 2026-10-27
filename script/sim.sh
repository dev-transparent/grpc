#!/bin/sh
# Deterministic simulation campaign: runs the simulator (spec/sim/sim.cr)
# for many seeds in parallel and reports the seeds that failed.
#
#   script/sim.sh [seeds] [first_seed] [duration_seconds]
#
# Environment:
#   JOBS=N          parallel processes (default: CPU count)
#   NO_FAULTS=1     disable fault injection (stricter oracle)
#   DETERMINISM=1   run every seed twice and require identical traces
#
# Replay a failure with: bin/sim --seed=SEED --verbose
set -e
cd "$(dirname "$0")/.."
SEEDS="${1:-200}"
FIRST="${2:-1}"
DURATION="${3:-30}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"
FLAGS="--duration=$DURATION"
[ -n "$NO_FAULTS" ] && FLAGS="$FLAGS --no-faults"
OUT=tmp/sim
mkdir -p bin "$OUT"
crystal build --release spec/sim/sim.cr -o bin/sim
rm -f "$OUT"/*.log "$OUT"/failed "$OUT"/nondeterministic

export DETERMINISM
seq "$FIRST" $((FIRST + SEEDS - 1)) | xargs -P "$JOBS" -I{} script/sim_seed.sh {} "$OUT" $FLAGS

OPS=$(cat "$OUT"/*.log | grep -o "ops=[0-9]*" | cut -d= -f2 | awk "{s+=\$1} END {print s+0}")
echo "$SEEDS seeds, $OPS calls simulated$( [ -n "$NO_FAULTS" ] && echo " (no faults)")"
STATUS=0
if [ -s "$OUT/nondeterministic" ]; then
  echo "NON-DETERMINISTIC seeds: $(sort -n "$OUT/nondeterministic" | tr '\n' ' ')"
  STATUS=1
elif [ -n "$DETERMINISM" ]; then
  echo "every seed replayed with an identical trace"
fi
if [ -s "$OUT/failed" ]; then
  FAILED=$(sort -n "$OUT/failed" | tr '\n' ' ')
  echo "FAILED seeds: $FAILED"
  for seed in $FAILED; do head -4 "$OUT/$seed.log"; done
  STATUS=1
fi
[ $STATUS -eq 0 ] && echo "all seeds passed"
exit $STATUS
