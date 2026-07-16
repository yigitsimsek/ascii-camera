#!/bin/zsh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$ROOT/.build/module-cache"
cd "$ROOT"
SDKROOT="$SDK" \
CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache" \
xcrun swift run --disable-sandbox ascii-camera-core-tests

SDKROOT="$SDK" \
CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache" \
xcrun swift build --disable-sandbox -c release --product ascii-camera-host

xcrun clang \
  -fobjc-arc \
  -fblocks \
  -Wall \
  -Wextra \
  -Werror \
  -fsyntax-only \
  -isysroot "$SDK" \
  -I "$ROOT/Native/OBSBridge/include" \
  "$ROOT/Native/OBSBridge/OBSModernCameraSink.m"

echo "OBS Camera Extension bridge compile check passed"
