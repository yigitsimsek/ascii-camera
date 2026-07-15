#!/bin/zsh
set -e
cd "$(dirname "$0")"
PORT=4173
URL="http://127.0.0.1:${PORT}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required. Install it, or run the folder with any local HTTP server."
  read -k 1 "?Press any key to close..."
  exit 1
fi

(sleep 0.8; open "$URL") &
echo "ASCII Camera is running at $URL"
echo "Press Control-C to stop it."
python3 -m http.server "$PORT" --bind 127.0.0.1
