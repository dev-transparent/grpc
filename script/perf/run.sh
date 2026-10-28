#!/bin/sh
# Benchmarks two builds of bench/perf.cr against each other.
#
#   script/perf/run.sh BASE_BINARY HEAD_BINARY OUT_DIR [ROUNDS]
#
# Wall-clock benchmarks run in interleaved rounds (base, head, head, base,
# ...) so drift in machine speed affects both sides equally. If valgrind is
# installed, the instructions executed per operation of every micro
# benchmark are also counted with cachegrind; these are deterministic and
# comparable even on noisy machines.
#
# Results are JSON lines in OUT_DIR/{base,head}/. BASE_BINARY may be "-"
# when there is no base to compare against.
set -e
BASE="$1"
HEAD="$2"
OUT="$3"
ROUNDS="${4:-6}"
DURATION="${PERF_DURATION:-0.5}"
MACRO_DURATION="${PERF_MACRO_DURATION:-2}"
mkdir -p "$OUT/base" "$OUT/head"

run() { # side binary round
  "$2" --duration="$DURATION" --macro-duration="$MACRO_DURATION" > "$OUT/$1/round-$3.jsonl"
}

i=1
while [ "$i" -le "$ROUNDS" ]; do
  echo "== round $i/$ROUNDS"
  if [ $((i % 2)) -eq 1 ]; then
    [ "$BASE" != "-" ] && run base "$BASE" "$i"
    run head "$HEAD" "$i"
  else
    run head "$HEAD" "$i"
    [ "$BASE" != "-" ] && run base "$BASE" "$i"
  fi
  i=$((i + 1))
done

# Instructions per operation: count a run of N and of 2N iterations and
# take the difference, which cancels out startup and setup costs. N is
# about 20ms of work (from the first round's timings, the same N for both
# sides), so that small run-to-run variation in startup (e.g. randomized
# hash seeds) is negligible.
instructions() { # binary bench iterations
  valgrind --tool=cachegrind --cache-sim=no --cachegrind-out-file=/dev/null \
    "$1" --bench="$2" --iterations="$3" 2>&1 >/dev/null | awk '/I *refs:/ { gsub(",", "", $NF); print $NF }'
}

iterations_for() { # bench
  awk -v b="\"bench\":\"$1\"" 'index($0, b) && /"metric":"time"/ {
    sub(/.*"value":/, ""); sub(/,.*/, ""); n = int(20000000 / $0)
  } END { if (n < 200) n = 200; if (n > 1000000) n = 1000000; print n }' "$OUT/head/round-1.jsonl"
}

count_instructions() { # side binary
  : > "$OUT/$1/instructions.jsonl"
  for bench in $("$2" --list); do
    n=$(iterations_for "$bench")
    small=$(instructions "$2" "$bench" "$n")
    large=$(instructions "$2" "$bench" $((n * 2)))
    [ -n "$small" ] && [ -n "$large" ] || continue
    awk -v b="$bench" -v s="$small" -v l="$large" -v n="$n" 'BEGIN {
      printf "{\"bench\":\"%s\",\"metric\":\"instructions\",\"value\":%.1f,\"unit\":\"instr/op\",\"better\":\"lower\"}\n", b, (l - s) / n
    }' >> "$OUT/$1/instructions.jsonl"
  done
}

if command -v valgrind > /dev/null; then
  echo "== counting instructions"
  [ "$BASE" != "-" ] && count_instructions base "$BASE"
  count_instructions head "$HEAD"
else
  echo "valgrind not found: skipping instruction counts"
fi
