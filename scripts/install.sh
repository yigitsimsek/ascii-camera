#!/bin/zsh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBS_PLUGIN="/Applications/OBS.app/Contents/Resources/obs-mac-virtualcam.plugin"
DAL_DIR="/Library/CoreMediaIO/Plug-Ins/DAL"
DAL_PLUGIN="$DAL_DIR/obs-mac-virtualcam.plugin"
BUILD_APP="$ROOT/.build/ASCII Camera.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.yigit.asciicamera.plist"
LAUNCH_JOB="gui/$(id -u)/com.yigit.asciicamera"

if [[ ! -d "$OBS_PLUGIN" && ! -d "$DAL_PLUGIN" ]]; then
  echo "The free installer needs the 552 KB legacy camera plug-in once."
  echo "Install OBS temporarily, or place obs-mac-virtualcam.plugin at:"
  echo "  $OBS_PLUGIN"
  exit 1
fi

"$ROOT/scripts/test.sh"

rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS"
install -m 755 "$ROOT/.build/release/ascii-camera-host" "$BUILD_APP/Contents/MacOS/ASCII Camera"
install -m 644 "$ROOT/Native/LegacyHost/Info.plist" "$BUILD_APP/Contents/Info.plist"
codesign --force --deep --sign - --identifier com.yigit.asciicamera "$BUILD_APP"

sudo rm -rf "/Applications/ASCII Camera.app"
sudo ditto "$BUILD_APP" "/Applications/ASCII Camera.app"
if [[ ! -d "$DAL_PLUGIN" ]]; then
  sudo mkdir -p "$DAL_DIR"
  sudo ditto "$OBS_PLUGIN" "$DAL_PLUGIN"
fi
sudo mkdir -p /usr/local/bin
sudo install -m 755 "$ROOT/bin/asciicam" /usr/local/bin/asciicam
mkdir -p "$HOME/Library/LaunchAgents"
launchctl bootout "$LAUNCH_JOB" >/dev/null 2>&1 || true
install -m 644 "$ROOT/Native/LegacyHost/com.yigit.asciicamera.plist" "$LAUNCH_AGENT"
if ! launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"; then
  echo "Could not load the ASCII Camera agent. Make sure OBS is fully quit, then rerun this installer."
  exit 1
fi

echo
echo "Installed the free ASCII Camera host and standalone 552 KB camera plug-in."
echo "No Apple Developer subscription is required, and OBS does not run."
echo "You may uninstall OBS now; do not remove $DAL_PLUGIN."
echo
echo "Quit OBS, then quit and reopen Arc, Zoom, Teams, Slack, or Discord. Run: asciicam"
echo "Select ‘OBS Virtual Camera’ in the calling app. Chrome, Safari, and Apple apps block legacy camera plug-ins."
