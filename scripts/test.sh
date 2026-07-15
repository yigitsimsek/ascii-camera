#!/bin/zsh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Some beta Command Line Tools releases ship a compiler one patch ahead of the
# current SDK. Prefer the stable 15.4 SDK when it is present and the default
# pair is incompatible; all APIs used by the core are available there.
if [[ "$(xcode-select -p 2>/dev/null)" == "/Library/Developer/CommandLineTools" && \
      -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi

mkdir -p "$ROOT/.build/module-cache"
cd "$ROOT"
SDKROOT="$SDK" \
CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache" \
xcrun swift run --disable-sandbox ascii-camera-core-tests
