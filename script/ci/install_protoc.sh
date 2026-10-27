#!/bin/sh
# Installs a protoc release (with its include directory) into DEST and
# prints the bin directory to add to PATH.
#
#   script/ci/install_protoc.sh [version] [dest]
set -e
VERSION="${1:-36.2}"
DEST="${2:-$HOME/.local/protoc-$VERSION}"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  PLATFORM=linux-x86_64 ;;
  Linux-aarch64) PLATFORM=linux-aarch_64 ;;
  Darwin-arm64)  PLATFORM=osx-aarch_64 ;;
  Darwin-x86_64) PLATFORM=osx-x86_64 ;;
  *) echo "unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
if [ ! -x "$DEST/bin/protoc" ]; then
  mkdir -p "$DEST"
  ZIP=$(mktemp)
  curl -sSfL "https://github.com/protocolbuffers/protobuf/releases/download/v$VERSION/protoc-$VERSION-$PLATFORM.zip" -o "$ZIP"
  unzip -q -o "$ZIP" -d "$DEST"
  rm -f "$ZIP"
fi
echo "$DEST/bin"
