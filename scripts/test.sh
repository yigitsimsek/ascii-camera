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

SDKROOT="$SDK" \
CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache" \
xcrun swift build --disable-sandbox -c release --product ascii-camera-host

TRANSPORT_TEST_APP="$ROOT/.build/LegacyTransportTests.app"
rm -rf "$TRANSPORT_TEST_APP"
mkdir -p "$TRANSPORT_TEST_APP/Contents/MacOS"
install -m 644 "$ROOT/Native/LegacyTransportTests/Info.plist" "$TRANSPORT_TEST_APP/Contents/Info.plist"
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -I "$ROOT/Native/LegacyTransport/include" \
  "$ROOT/Native/LegacyTransport/LegacyVirtualCameraServer.m" \
  "$ROOT/Native/LegacyTransportTests/main.m" \
  -framework Foundation \
  -framework CoreVideo \
  -framework IOSurface \
  -o "$TRANSPORT_TEST_APP/Contents/MacOS/legacy-transport-tests"
codesign --force --sign - "$TRANSPORT_TEST_APP"

TRANSPORT_TEST_PLIST="$ROOT/.build/com.yigit.asciicamera.transport-test.plist"
install -m 644 "$ROOT/Native/LegacyTransportTests/com.yigit.asciicamera.transport-test.plist" "$TRANSPORT_TEST_PLIST"
plutil -replace ProgramArguments -json \
  "[\"$TRANSPORT_TEST_APP/Contents/MacOS/legacy-transport-tests\"]" \
  "$TRANSPORT_TEST_PLIST"
TEST_DOMAIN="gui/$(id -u)"
TEST_JOB="$TEST_DOMAIN/com.yigit.asciicamera.transport-test"
launchctl bootout "$TEST_JOB" >/dev/null 2>&1 || true
if ! launchctl bootstrap "$TEST_DOMAIN" "$TRANSPORT_TEST_PLIST" 2>/dev/null; then
  echo "Legacy IOSurface transport runtime test skipped (launchd is unavailable in this shell)."
  exit 0
fi
trap 'launchctl bootout "$TEST_JOB" >/dev/null 2>&1 || true' EXIT
launchctl kickstart -k "$TEST_JOB"
for _ in {1..50}; do
  JOB_STATE="$(launchctl print "$TEST_JOB" 2>&1 || true)"
  if [[ "$JOB_STATE" == *"last exit code = 0"* ]]; then
    echo "Legacy IOSurface transport test passed"
    break
  fi
  if [[ "$JOB_STATE" == *"last exit code ="* ]]; then
    echo "$JOB_STATE"
    echo "Legacy IOSurface transport test failed."
    exit 1
  fi
  sleep 0.1
done
if [[ "${JOB_STATE:-}" != *"last exit code = 0"* ]]; then
  echo "$JOB_STATE"
  echo "Legacy IOSurface transport test timed out."
  exit 1
fi
