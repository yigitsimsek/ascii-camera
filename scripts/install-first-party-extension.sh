#!/bin/zsh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="${ASCII_CAMERA_TEAM_ID:-${1:-}}"
DERIVED_DATA="$ROOT/DerivedData"
LAUNCH_JOB="gui/$(id -u)/com.yigit.asciicamera"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.yigit.asciicamera.plist"

if [[ ! -d /Applications/Xcode.app ]]; then
  echo "Full Xcode is required to sign a macOS Camera Extension."
  exit 1
fi

if [[ -z "$TEAM_ID" ]]; then
  echo "Usage: scripts/install-first-party-extension.sh PAID_APPLE_DEVELOPER_TEAM_ID"
  echo "Apple Personal Teams cannot provision a System Extension."
  exit 2
fi

"$ROOT/scripts/test.sh"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project "$ROOT/Experimental/FirstPartyCameraExtension/FirstPartyCameraExtension.xcodeproj" \
  -scheme "ASCII Camera" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/ASCII Camera.app"
launchctl bootout "$LAUNCH_JOB" >/dev/null 2>&1 || true
rm -f "$LAUNCH_AGENT"
sudo rm -rf "/Applications/ASCII Camera.app"
sudo ditto "$BUILT_APP" "/Applications/ASCII Camera.app"
sudo mkdir -p /usr/local/bin
sudo install -m 755 "$ROOT/bin/asciicam" /usr/local/bin/asciicam

echo "Installed the experimental first-party Camera Extension build."
