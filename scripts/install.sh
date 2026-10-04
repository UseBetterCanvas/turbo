#!/usr/bin/env bash
# Installs (or updates) Turbo into /Applications and launches it.
#
#   curl -fsSL https://raw.githubusercontent.com/UseBetterCanvas/turbo/main/scripts/install.sh | bash
#
# Downloading with curl skips the "downloaded from the internet" quarantine flag, so macOS
# opens Turbo without the "Apple could not verify" prompt (Turbo isn't notarized yet).
set -euo pipefail

URL="https://github.com/UseBetterCanvas/turbo/releases/download/latest-build/Turbo.zip"
DEST="/Applications"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Turbo…"
curl -fsSL "$URL" -o "$TMP/Turbo.zip"
ditto -x -k "$TMP/Turbo.zip" "$TMP"

# Quit a running copy so it can be replaced.
osascript -e 'quit app "Turbo"' >/dev/null 2>&1 || true
pkill -x Turbo >/dev/null 2>&1 || true

if [[ -w "$DEST" ]]; then
  rm -rf "$DEST/Turbo.app"
  ditto "$TMP/Turbo.app" "$DEST/Turbo.app"
else
  echo "Installing to $DEST needs your password."
  sudo rm -rf "$DEST/Turbo.app"
  sudo ditto "$TMP/Turbo.app" "$DEST/Turbo.app"
fi
xattr -dr com.apple.quarantine "$DEST/Turbo.app" 2>/dev/null || true

open "$DEST/Turbo.app"
echo "Turbo is running. Look for the flame in your menu bar."
