#!/bin/zsh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBS_APP="/Applications/OBS.app"
OBS_EXTENSION="$OBS_APP/Contents/Library/SystemExtensions/com.obsproject.obs-studio.mac-camera-extension.systemextension"
OBS_EXTENSION_ID="com.obsproject.obs-studio.mac-camera-extension"
BUILD_APP="$ROOT/.build/ASCII Camera.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.yigit.asciicamera.plist"
LAUNCH_JOB="gui/$(id -u)/com.yigit.asciicamera"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Apple Command Line Tools are required. Install them with: xcode-select --install"
  exit 1
fi

obs_extension_state() {
  local line
  line="$(systemextensionsctl list 2>/dev/null | grep -F "$OBS_EXTENSION_ID" || true)"
  if [[ "$line" == *"[activated enabled]"* ]]; then
    echo "activated"
  elif [[ "$line" == *"waiting for user"* ]]; then
    echo "approval pending"
  elif [[ -n "$line" ]]; then
    echo "registered but unavailable"
  else
    echo "not activated"
  fi
}

if [[ ! -d "$OBS_EXTENSION" ]]; then
  echo "The free installer needs OBS's signed Camera Extension."
  echo "Install the current OBS release in /Applications, then rerun this script."
  exit 1
fi

if ! codesign --verify --deep --strict "$OBS_APP" >/dev/null 2>&1; then
  echo "The installed OBS application has an invalid or damaged Apple code signature:"
  echo "  $OBS_APP"
  echo
  echo "macOS will not register its Camera Extension, so no extension setting or"
  echo "OBS Virtual Camera device can appear. Reinstall OBS from the official DMG,"
  echo "choose Replace when copying it to /Applications, then rerun this script."
  exit 1
fi

"$ROOT/scripts/test.sh"

rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS"
install -m 755 "$ROOT/.build/release/ascii-camera-host" "$BUILD_APP/Contents/MacOS/ASCII Camera"
install -m 644 "$ROOT/Native/Host/Info.plist" "$BUILD_APP/Contents/Info.plist"
codesign --force --deep --sign - --identifier com.yigit.asciicamera "$BUILD_APP"

sudo rm -rf "/Applications/ASCII Camera.app"
sudo ditto "$BUILD_APP" "/Applications/ASCII Camera.app"
sudo mkdir -p /usr/local/bin
sudo install -m 755 "$ROOT/bin/asciicam" /usr/local/bin/asciicam
mkdir -p "$HOME/Library/LaunchAgents"
launchctl bootout "$LAUNCH_JOB" >/dev/null 2>&1 || true
install -m 644 "$ROOT/Native/Host/com.yigit.asciicamera.plist" "$LAUNCH_AGENT"
if ! launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"; then
  echo "Could not load the ASCII Camera agent. Rerun this installer from your logged-in desktop session."
  exit 1
fi

echo
echo "Installed the free ASCII Camera host. No Apple Developer subscription is required."
EXTENSION_STATE="$(obs_extension_state)"
if [[ "$EXTENSION_STATE" == "activated" ]]; then
  echo "OBS Camera Extension: activated"
  echo "Quit OBS completely, then run: asciicam"
else
  echo
  echo "OBS Camera Extension: $EXTENSION_STATE"
  echo "ONE-TIME APPROVAL REQUIRED:"
  echo "  1. Run: open -a OBS --args --startvirtualcam"
  echo "  2. Approve OBS Virtual Camera under System Settings > General"
  echo "     > Login Items & Extensions > Camera Extensions."
  echo "  3. Restart OBS and click Start Virtual Camera once."
  echo "  4. Once it starts, quit OBS completely, then run: asciicam"
fi
echo "Daily use does not run the OBS application. Keep it installed because it owns the signed Camera Extension."

if [[ -f "$HOME/.zshrc" ]] && grep -Eq '^[[:space:]]*alias[[:space:]]+asciicam=.*start\.command' "$HOME/.zshrc"; then
  echo
  echo "WARNING: ~/.zshrc still aliases asciicam to the old browser launcher."
  echo "Remove that alias and open a new terminal before using the native command."
fi
