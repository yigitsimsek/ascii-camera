#!/bin/zsh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$ROOT/.build/module-cache"
cd "$ROOT"
SDKROOT="$SDK" \
CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache" \
xcrun swift run --disable-sandbox -c release ascii-camera-benchmarks
