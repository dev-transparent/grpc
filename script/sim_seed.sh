#!/bin/sh
# Runs one simulation seed for script/sim.sh: sim_seed.sh SEED OUT_DIR FLAGS...
seed=$1
out=$2
shift 2
./bin/sim --seed="$seed" "$@" > "$out/$seed.log" 2>&1 || echo "$seed" >> "$out/failed"
if [ -n "$DETERMINISM" ]; then
  first=$(grep -o "trace=[0-9a-f]*" "$out/$seed.log" | head -1)
  second=$(./bin/sim --seed="$seed" "$@" 2>&1 | grep -o "trace=[0-9a-f]*" | head -1)
  [ "$first" = "$second" ] || echo "$seed ($first vs $second)" >> "$out/nondeterministic"
fi
exit 0
