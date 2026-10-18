#!/bin/bash
# Headroom installer.
#
#   curl -fsSL https://raw.githubusercontent.com/0xgeorgemathew/headroom/main/install.sh | bash
#
# Downloads the newest release (betas included), removes the download quarantine (the app is
# signed but not notarized), installs Headroom.app to /Applications (or ~/Applications when
# /Applications isn't writable), links the `headroom` CLI into ~/.local/bin with its man page,
# and opens the app.
#
# Options:
#   bash -s -- --version v0.1.0-beta.1   install a specific release
#   bash -s -- --uninstall               remove the app and the CLI links (keeps your data)
#   bash -s -- --uninstall --purge       also remove ~/Library/Application Support/Headroom
set -euo pipefail

REPO="0xgeorgemathew/headroom"
APP_NAME="Headroom.app"
BIN_DIR="$HOME/.local/bin"
MAN_DIR="$HOME/.local/share/man/man1"
DATA_DIR="$HOME/Library/Application Support/Headroom"

version=""
uninstall=0
purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    --purge) purge=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

quit_app() {
  osascript -e 'tell application id "com.headroom.app" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do pgrep -x HeadroomApp >/dev/null || return 0; sleep 1; done
  pkill -x HeadroomApp >/dev/null 2>&1 || true
}

installed_app() {
  for dir in /Applications "$HOME/Applications"; do
    [ -d "$dir/$APP_NAME" ] && { echo "$dir/$APP_NAME"; return 0; }
  done
  return 1
}

if [ "$uninstall" = 1 ]; then
  say "Quitting Headroom"
  quit_app
  if app=$(installed_app); then
    say "Removing $app"
    rm -rf "$app"
  fi
  rm -f "$BIN_DIR/headroom" "$MAN_DIR/headroom.1"
  if [ "$purge" = 1 ]; then
    say "Removing $DATA_DIR"
    rm -rf "$DATA_DIR"
  fi
  say "Headroom is uninstalled."
  exit 0
fi

# Requirements: Apple silicon, macOS 26 or later.
[ "$(uname -s)" = "Darwin" ] || fail "Headroom runs on macOS."
[ "$(uname -m)" = "arm64" ] || fail "Headroom needs an Apple silicon Mac."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || fail "Headroom needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))."

# Find the release asset.
if [ -n "$version" ]; then
  api="https://api.github.com/repos/$REPO/releases/tags/$version"
else
  api="https://api.github.com/repos/$REPO/releases?per_page=1"
fi
say "Looking up the ${version:-latest} release"
url=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api" \
  | grep -o '"browser_download_url": *"[^"]*/Headroom-[^"]*\.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/') || true
[ -n "$url" ] || fail "Couldn't find a Headroom release on github.com/$REPO."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
say "Downloading ${url##*/}"
curl -fL --progress-bar "$url" -o "$tmp/Headroom.zip"
if curl -fsSL "$url.sha256" -o "$tmp/Headroom.zip.sha256" 2>/dev/null; then
  expected=$(awk '{print $1}' "$tmp/Headroom.zip.sha256")
  actual=$(shasum -a 256 "$tmp/Headroom.zip" | awk '{print $1}')
  [ "$expected" = "$actual" ] || fail "Checksum mismatch for ${url##*/}."
  say "Checksum verified"
fi
ditto -x -k "$tmp/Headroom.zip" "$tmp/unzipped"
[ -d "$tmp/unzipped/$APP_NAME" ] || fail "The download didn't contain $APP_NAME."

# Not notarized: clear the quarantine flag so Gatekeeper doesn't block the first launch.
xattr -dr com.apple.quarantine "$tmp/unzipped/$APP_NAME" 2>/dev/null || true

dest_dir=/Applications
[ -w "$dest_dir" ] || { dest_dir="$HOME/Applications"; mkdir -p "$dest_dir"; }
say "Installing to $dest_dir/$APP_NAME"
quit_app
rm -rf "$dest_dir/$APP_NAME"
ditto "$tmp/unzipped/$APP_NAME" "$dest_dir/$APP_NAME"
xattr -dr com.apple.quarantine "$dest_dir/$APP_NAME" 2>/dev/null || true

say "Linking the headroom command and man page"
mkdir -p "$BIN_DIR" "$MAN_DIR"
ln -sf "$dest_dir/$APP_NAME/Contents/MacOS/headroom" "$BIN_DIR/headroom"
ln -sf "$dest_dir/$APP_NAME/Contents/Resources/headroom.1" "$MAN_DIR/headroom.1"

say "Opening Headroom"
open "$dest_dir/$APP_NAME"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '\nAdd ~/.local/bin to your PATH to use the CLI:\n  echo '"'"'export PATH="$HOME/.local/bin:$PATH"'"'"' >> ~/.zshrc\n' ;;
esac
printf '\nHeadroom is in your menu bar. Turn on "Launch at login" in its Settings.\n'
