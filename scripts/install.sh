#!/bin/zsh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="${ASCII_CAMERA_TEAM_ID:-${1:-}}"
DERIVED_DATA="$ROOT/DerivedData"

if [[ ! -d /Applications/Xcode.app ]]; then
  echo "Full Xcode is required to sign a macOS Camera Extension. Install Xcode, open it once, then rerun this script."
  exit 1
fi

if [[ -z "$TEAM_ID" ]]; then
  echo "Usage: scripts/install.sh YOUR_APPLE_DEVELOPER_TEAM_ID"
  echo "You can find the Team ID in Xcode > Settings > Accounts."
  exit 2
fi

"$ROOT/scripts/test.sh"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project "$ROOT/AsciiCamera.xcodeproj" \
  -scheme "ASCII Camera" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/ASCII Camera.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Build succeeded but $BUILT_APP was not found."
  exit 1
fi

sudo rm -rf "/Applications/ASCII Camera.app"
sudo ditto "$BUILT_APP" "/Applications/ASCII Camera.app"
sudo mkdir -p /usr/local/bin
sudo install -m 755 "$ROOT/bin/asciicam" /usr/local/bin/asciicam

echo "Installed ASCII Camera and /usr/local/bin/asciicam."
echo "Run ‘asciicam’. On first launch, approve camera access and the Camera Extension when macOS asks."
