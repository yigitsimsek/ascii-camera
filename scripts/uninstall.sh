#!/bin/zsh
set -eu

LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.yigit.asciicamera.plist"
LAUNCH_JOB="gui/$(id -u)/com.yigit.asciicamera"

if [[ -x /usr/local/bin/asciicam ]]; then
  /usr/local/bin/asciicam stop >/dev/null 2>&1 || true
fi

launchctl bootout "$LAUNCH_JOB" >/dev/null 2>&1 || true
rm -f "$LAUNCH_AGENT"
sudo rm -rf "/Applications/ASCII Camera.app"
sudo rm -f /usr/local/bin/asciicam
defaults delete com.yigit.asciicamera >/dev/null 2>&1 || true

echo "ASCII Camera was removed. OBS Studio was left untouched."
