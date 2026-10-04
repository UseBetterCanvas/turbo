#!/usr/bin/env bash
# Installs (or updates) Turbo into /Applications and launches it.
#
#   bash <(gh api repos/UseBetterCanvas/turbo/contents/scripts/install.sh -H "Accept: application/vnd.github.raw")
#
# The repo is private, so this uses the GitHub CLI (https://cli.github.com) to download.
# Downloading from the command line also skips macOS's "Apple could not verify" prompt,
# since only browser downloads get flagged as coming from the internet.
set -euo pipefail

REPO="UseBetterCanvas/turbo"
DEST="/Applications"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v gh >/dev/null 2>&1; then
  echo "Turbo installs with the GitHub CLI. Install it with: brew install gh"
  echo "Then sign in with: gh auth login"
  exit 1
fi
# Only github.com matters here (other configured hosts can be signed out).
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "Sign in to GitHub first: gh auth login"
  exit 1
fi

echo "Downloading Turbo…"
if ! gh release download latest-build --repo "$REPO" --pattern Turbo.zip --dir "$TMP" --clobber; then
  echo "Couldn't download Turbo. Check that your GitHub account can see $REPO (gh auth status)."
  exit 1
fi
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
echo "Turbo is running. Look for the paw in your menu bar."
