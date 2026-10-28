#!/bin/sh
# Runs protobuf's official conformance suite against the Crystal runtime.
#
#   1. Downloads the protobuf sources matching the installed protoc (into
#      tmp/conformance/protobuf-src) and builds `conformance_test_runner`
#      with CMake, using an installed Abseil (e.g. `brew install abseil`).
#   2. Builds the testee (spec/protobuf/conformance/testee.cr).
#   3. Runs the binary + JSON suite for proto2, proto3 and editions test
#      messages (text format requests are reported as skipped) with
#      recommended tests enforced, writing results to
#      tmp/conformance/results.
#
# Expected failures are listed in spec/protobuf/conformance/failure_list.txt.
# Environment:
#   PROTOBUF_VERSION  protobuf release to build (default: from `protoc --version`)
#   CONFORMANCE_RUNNER  use an existing conformance_test_runner binary
#   JOBS              build parallelism (default: 8)
#   ABSL_PROVIDER     "package" (an installed Abseil, default) or "module"
#                     (let CMake fetch Abseil)
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
WORK="$ROOT/tmp/conformance"
VERSION="${PROTOBUF_VERSION:-$(protoc --version | awk '{print $2}')}"
SRC="$WORK/protobuf-src"
BUILD="$WORK/build"
RESULTS="$WORK/results"
JOBS="${JOBS:-8}"
mkdir -p "$WORK" "$RESULTS" bin

RUNNER="${CONFORMANCE_RUNNER:-$BUILD/conformance_test_runner}"
# A runner restored without its shared libraries (e.g. from a CI cache) is
# rebuilt.
if [ -x "$RUNNER" ] && command -v ldd > /dev/null && ldd "$RUNNER" | grep -q "not found"; then
  echo "== $RUNNER is missing shared libraries; rebuilding"
  RUNNER="$BUILD/conformance_test_runner"
  rm -f "$RUNNER"
fi
if [ ! -x "$RUNNER" ]; then
  if [ ! -d "$SRC" ]; then
    echo "== Fetching protobuf v$VERSION"
    git clone --quiet --depth 1 --branch "v$VERSION" https://github.com/protocolbuffers/protobuf.git "$SRC"
  fi
  echo "== Building conformance_test_runner (protobuf v$VERSION)"
  cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 \
    -Dprotobuf_ABSL_PROVIDER="${ABSL_PROVIDER:-package}" -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_CONFORMANCE=ON -Dprotobuf_INSTALL=OFF > "$WORK/cmake.log"
  cmake --build "$BUILD" --target conformance_test_runner -j "$JOBS" > "$WORK/build.log"
fi

echo "== Building the testee"
crystal build --release spec/protobuf/conformance/testee.cr -o bin/conformance_testee

echo "== Running the conformance suite"
cd "$RESULTS"
STATUS=0
"$RUNNER" --maximum_edition UNSTABLE --enforce_recommended \
  --failure_list "$ROOT/spec/protobuf/conformance/failure_list.txt" \
  --text_format_failure_list "$ROOT/spec/protobuf/conformance/text_format_failure_list.txt" \
  --output_dir "$RESULTS" "$ROOT/bin/conformance_testee" > "$RESULTS/conformance.log" 2>&1 || STATUS=$?
grep "CONFORMANCE SUITE" "$RESULTS/conformance.log" | tee "$RESULTS/summary.txt"
if [ $STATUS -ne 0 ]; then
  grep "^ERROR" "$RESULTS/conformance.log" | cut -c1-400 || true
  echo "Conformance failures; see $RESULTS/conformance.log"
fi
exit $STATUS
