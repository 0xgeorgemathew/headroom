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
#
# Written for the bash 3.2 that ships with macOS.
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

# ── Look ──────────────────────────────────────────────────────────────────────────────────────
# A terminal gets the meter-H, live steps and a download meter, all drawn from the app icon:
# azure and sky are the lit cells, the terminal's own foreground stands in for the pearl
# crossbar, and amber and rose mean what they mean in the app. Pipes, CI and NO_COLOR get
# plain lines.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then fancy=1; else fancy=0; fi

RESET="" BOLD="" DIM="" AZURE="" SKY="" AMBER="" ROSE=""
if [ "$fancy" = 1 ]; then
  RESET=$'\033[0m' BOLD=$'\033[1m' DIM=$'\033[2m'
  case "${COLORTERM:-}" in
    truecolor|24bit)
      AZURE=$'\033[38;2;74;142;255m' SKY=$'\033[38;2;125;180;255m'
      AMBER=$'\033[38;2;255;194;72m' ROSE=$'\033[38;2;255;105;130m' ;;
    *) # Terminal.app before macOS 26 has no 24-bit color; these are the nearest 256-color cells.
      AZURE=$'\033[38;5;69m' SKY=$'\033[38;5;111m' AMBER=$'\033[38;5;221m' ROSE=$'\033[38;5;204m' ;;
  esac
fi
GHOST="$RESET$DIM"

cols=""
[ "$fancy" = 1 ] && { cols=$(stty size 2>/dev/null </dev/tty | awk '{print $2}') || true; }
[ "${cols:-0}" -gt 0 ] 2>/dev/null || cols=${COLUMNS:-80}

# The mark: two five-cell meters, lit to the crossbar, with headroom dim above it.
mark() {
  local subtitle=$1 cell="▆▆▆" gap="   "
  [ "$fancy" = 1 ] || { printf '\nHeadroom · %s\n\n' "$subtitle"; return; }
  printf '\n'
  printf '  %s%s%s%s%s\n' "$DIM$ROSE" "$cell" "$gap" "$cell" "$RESET"
  printf '  %s%s%s%s%s\n' "$DIM$AMBER" "$cell" "$gap" "$cell" "$RESET"
  printf '  %s%s▅▅▅%s%s   %sHeadroom%s\n' "$BOLD" "$cell" "$cell" "$RESET" "$BOLD" "$RESET"
  printf '  %s%s%s%s%s   %s%s%s\n' "$SKY" "$cell" "$gap" "$cell" "$RESET" "$DIM" "$subtitle" "$RESET"
  printf '  %s%s%s%s%s\n\n' "$AZURE" "$cell" "$gap" "$cell" "$RESET"
}

# ── Steps ─────────────────────────────────────────────────────────────────────────────────────
# One line per step: a cell, what happened, and a dim detail. While a step runs, its cell is a
# small level meter rising and falling; when it ends, the line is rewritten in place.

FRAMES=(▁ ▂ ▃ ▄ ▅ ▆ ▅ ▄ ▃ ▂)
active=""  # label of the step on screen, if any
worker=""  # background job the current step is waiting on

# Columns: two spaces, the cell, two spaces, a 30-wide label, then the detail.
LABEL=30
line() { # color glyph label detail
  printf '  %s%s%s  %-*s %s%s%s' "$1" "$2" "$RESET" "$LABEL" "$3" "$DIM" "$4" "$RESET"
}

# Trims a plain detail to the window so finished lines don't wrap; very narrow windows drop it.
fit() {
  local room=$((cols - LABEL - 6)) text=$1
  if [ "$room" -lt 8 ]; then return; fi
  [ "${#text}" -le "$room" ] || text="${text:0:$((room - 1))}…"
  printf '%s' "$text"
}

begin() { # label
  active=$1
  [ "$fancy" = 1 ] && line "$AZURE" "${FRAMES[0]}" "$active" ""
  return 0
}

# Waits for a background job, animating the active step. An optional function supplies a live
# detail (the download meter). Returns the job's exit status.
await() { # pid [detail-fn]
  local pid=$1 fn=${2:-} i=0 detail=""
  worker=$pid
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$fancy" = 1 ]; then
      # The line is redrawn with \r, so it must never wrap: narrow windows get no live detail.
      [ -n "$fn" ] && [ "$cols" -ge $((LABEL + 22)) ] && detail=$($fn)
      printf '\r\033[2K'; line "$AZURE" "${FRAMES[$((i % ${#FRAMES[@]}))]}" "$active" "$detail"
    fi
    i=$((i + 1))
    sleep 0.08
  done
  worker=""
  wait "$pid"
}

finish() { # glyph-color plain-glyph label detail
  if [ "$fancy" = 1 ]; then
    printf '\r\033[2K'; line "$1" "▆" "$3" "$(fit "$4")"; printf '\n'
  else
    printf '  %s %-*s %s\n' "$2" "$LABEL" "$3" "$4"
  fi
  active=""
}
done_() { finish "$AZURE" "✓" "$1" "${2:-}"; }
warn() { finish "$AMBER" "!" "$1" "${2:-}"; }

# Ends the install: what went wrong, then how to fix it.
fail() { # headline hint
  if [ "$fancy" = 1 ]; then
    [ -n "$active" ] && printf '\r\033[2K'
    printf '  %s▆%s  %s%s%s\n' "$ROSE" "$RESET" "$BOLD" "$1" "$RESET" >&2
    [ -n "${2:-}" ] && printf '     %s%s%s\n' "$DIM" "$2" "$RESET" >&2
    printf '\n' >&2
  else
    printf '  ✗ %s\n' "$1" >&2
    [ -n "${2:-}" ] && printf '    %s\n' "$2" >&2
  fi
  active=""
  exit 1
}

tmp=""
cleanup() {
  [ -n "$worker" ] && kill "$worker" 2>/dev/null
  if [ "$fancy" = 1 ]; then
    [ -n "$active" ] && printf '\n'
    printf '\033[?25h'
  fi
  [ -n "$tmp" ] && rm -rf "$tmp"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
[ "$fancy" = 1 ] && printf '\033[?25l'

# ── Helpers ───────────────────────────────────────────────────────────────────────────────────

# curl has no timeouts by default, so a stalled connection hangs the install with no output.
# Some networks take seconds to connect to GitHub's download host, and now and then a minute or
# more; a connect that takes over 10 seconds is retried instead of waited out. Small requests
# get a hard cap; the download aborts if it stays under 1 KB/s for 30 seconds.
fetch() { curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 1 "$@"; }
download() { curl -fsSL --connect-timeout 10 --speed-limit 1024 --speed-time 30 --retry 3 --retry-delay 1 "$@"; }

megabytes() { awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1000000 }'; }
tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

quit_app() {
  pgrep -x HeadroomApp >/dev/null || return 0
  # Ask politely in the background: the Apple event can sit behind an Automation prompt.
  osascript -e 'tell application id "com.headroom.app" to quit' >/dev/null 2>&1 &
  local asker=$!
  for _ in 1 2 3 4 5; do pgrep -x HeadroomApp >/dev/null || break; sleep 1; done
  kill "$asker" >/dev/null 2>&1 || true
  pkill -x HeadroomApp >/dev/null 2>&1 || true
}

installed_app() {
  for dir in /Applications "$HOME/Applications"; do
    [ -d "$dir/$APP_NAME" ] && { echo "$dir/$APP_NAME"; return 0; }
  done
  return 1
}

# ── Uninstall ─────────────────────────────────────────────────────────────────────────────────

if [ "$uninstall" = 1 ]; then
  mark "Uninstalling"
  if pgrep -x HeadroomApp >/dev/null; then
    begin "Quitting Headroom"
    quit_app & await $! || true
    done_ "Quit Headroom"
  fi
  if app=$(installed_app); then
    rm -rf "$app"
    done_ "Removed the app" "$(tilde "$app")"
  else
    done_ "No app to remove" "not in Applications"
  fi
  rm -f "$BIN_DIR/headroom" "$MAN_DIR/headroom.1"
  done_ "Removed the headroom command" "$(tilde "$BIN_DIR/headroom")"
  if [ "$purge" = 1 ]; then
    rm -rf "$DATA_DIR"
    done_ "Removed your history" "$(tilde "$DATA_DIR")"
  fi
  printf '\n  %sHeadroom is uninstalled.%s\n' "$BOLD" "$RESET"
  if [ "$purge" != 1 ]; then
    printf '  %sYour history is still in %s.%s\n' "$DIM" "$(tilde "$DATA_DIR")" "$RESET"
    printf '  %sTo remove it too, run the uninstall again with --purge.%s\n' "$DIM" "$RESET"
  fi
  printf '\n'
  exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────────────────────────

mark "Will this week's allowance last?"

begin "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || fail "Headroom runs on macOS" "This computer runs $(uname -s)."
[ "$(uname -m)" = "arm64" ] || fail "Headroom needs a Mac with Apple silicon" "This Mac has an Intel processor."
os=$(sw_vers -productVersion)
major=${os%%.*}
[ "$major" -ge 15 ] || fail "Headroom needs macOS 15 or later" "This Mac runs macOS $os. Update it in System Settings › General › Software Update."
chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple silicon")
done_ "Checked this Mac" "macOS $os · $chip"

tmp=$(mktemp -d)

if [ -n "$version" ]; then
  begin "Finding Headroom $version"
  api="https://api.github.com/repos/$REPO/releases/tags/$version"
else
  begin "Finding the latest release"
  api="https://api.github.com/repos/$REPO/releases?per_page=1"
fi
fetch -H "Accept: application/vnd.github+json" "$api" -o "$tmp/release.json" 2>/dev/null & await $! \
  || fail "Couldn't reach GitHub" "Check your connection and run the installer again in a minute."
# Each asset lists its size just before its download URL; pair them and keep the app zip.
size="" url=""
read -r size url < <(grep -oE '"(size|browser_download_url)": *("[^"]*"|[0-9]+)' "$tmp/release.json" \
  | sed -E 's/^"[a-z_]+": *"?//; s/"$//' | paste - - | grep -E '/Headroom-[^/]*\.zip$' | head -1) || true
[ -n "$url" ] || fail "Couldn't find a Headroom release" "github.com/$REPO has no release${version:+ named $version} with an app to download."
tag=$(grep -oE '"tag_name": *"[^"]*"' "$tmp/release.json" | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
published=$(grep -oE '"published_at": *"[^"]*"' "$tmp/release.json" | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
released=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$published" "+%b %e" 2>/dev/null | tr -s ' ') || true
done_ "Found Headroom ${tag#v}" "${released:+released $released · }$(megabytes "${size:-0}")"

# The live detail while downloading: an LED meter whose leading cell is the bright "now" cell.
progress() {
  local got total=${size:-0} width lit i bar=""
  got=$(stat -f%z "$tmp/Headroom.zip" 2>/dev/null || echo 0)
  [ "$got" -gt 0 ] || { printf 'Connecting to GitHub…'; return; }
  [ "$total" -gt 0 ] 2>/dev/null || { megabytes "$got"; return; }
  width=$((cols - LABEL - 22)); [ "$width" -gt 24 ] && width=24
  if [ "$width" -ge 8 ]; then
    lit=$((got * width / total)); [ "$lit" -gt "$width" ] && lit=$width
    # Braces matter here: bash 3.2 reads a multibyte character right after $NAME as part of it.
  for ((i = 0; i < width; i++)); do
      if [ "$i" -lt $((lit - 1)) ]; then bar+="${RESET}${AZURE}▌"; elif [ "$i" -eq $((lit - 1)) ]; then bar+="${RESET}${SKY}▌"; else bar+="${GHOST}▌"; fi
    done
    bar+="$RESET$DIM  "
  fi
  printf '%s%s of %s' "$bar" "$(megabytes "$got" | cut -d' ' -f1)" "$(megabytes "$total")"
}
begin "Downloading"
# One curl for both files: the checksum reuses the zip's connection instead of opening its own.
# Its exit status reflects whichever transfer failed last, so judge the files instead.
download "$url" -o "$tmp/Headroom.zip" "$url.sha256" -o "$tmp/Headroom.zip.sha256" 2>/dev/null & await $! progress || true
got=$(stat -f%z "$tmp/Headroom.zip" 2>/dev/null || echo 0)
if [ "$got" -eq 0 ] || { [ -n "$size" ] && [ "$got" -ne "$size" ]; }; then
  fail "The download stalled" "Check your connection and run the installer again. Nothing was changed."
fi
done_ "Downloaded" "$(megabytes "$got")"

begin "Verifying the download"
if grep -qE '^[0-9a-f]{64}' "$tmp/Headroom.zip.sha256" 2>/dev/null; then
  expected=$(awk '{print $1}' "$tmp/Headroom.zip.sha256")
  actual=$(shasum -a 256 "$tmp/Headroom.zip" | awk '{print $1}')
  [ "$expected" = "$actual" ] || fail "The download doesn't match its checksum" \
    "Nothing was installed. Run the installer again; if this keeps happening, open an issue at github.com/$REPO."
  verified=1
else
  verified=0
fi
ditto -x -k "$tmp/Headroom.zip" "$tmp/unzipped"
[ -d "$tmp/unzipped/$APP_NAME" ] || fail "The download doesn't contain $APP_NAME" "Open an issue at github.com/$REPO."
# Older releases need a newer macOS than the installer does; stop before replacing anything.
needs=$(plutil -extract LSMinimumSystemVersion raw "$tmp/unzipped/$APP_NAME/Contents/Info.plist" 2>/dev/null || echo 0)
[ "$major" -ge "${needs%%.*}" ] || fail "Headroom ${tag#v} needs macOS ${needs%%.*} or later" \
  "This Mac runs macOS $os. Nothing was changed."
if [ "$verified" = 1 ]; then
  done_ "Verified the download" "SHA-256 matches"
else
  warn "Couldn't verify the download" "no checksum published; installing anyway"
fi

# Not notarized: clear the quarantine flag so Gatekeeper doesn't block the first launch.
xattr -dr com.apple.quarantine "$tmp/unzipped/$APP_NAME" 2>/dev/null || true

dest_dir=/Applications
[ -w "$dest_dir" ] || { dest_dir="$HOME/Applications"; mkdir -p "$dest_dir"; }
app="$dest_dir/$APP_NAME"
begin "Installing"
quit_app & await $! || true
rm -rf "$app"
ditto "$tmp/unzipped/$APP_NAME" "$app"
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
done_ "Installed" "$(tilde "$app")"

mkdir -p "$BIN_DIR" "$MAN_DIR"
ln -sf "$app/Contents/MacOS/headroom" "$BIN_DIR/headroom"
ln -sf "$app/Contents/Resources/headroom.1" "$MAN_DIR/headroom.1"
done_ "Linked the headroom command" "$(tilde "$BIN_DIR/headroom")"

begin "Opening Headroom"
open "$app" 2>/dev/null || fail "Headroom is installed but didn't open" "Open it from $(tilde "$dest_dir") in Finder."
done_ "Opened Headroom"

printf '\n  %sHeadroom is in your menu bar.%s\n' "$BOLD" "$RESET"
printf '  %sTo start it with your Mac, turn on Launch at login in its Settings.%s\n' "$DIM" "$RESET"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    if [ "$fancy" = 1 ]; then printf '\n  %s▆%s  ' "$AMBER" "$RESET"; else printf '\n  ! '; fi
    printf 'The headroom command isn'"'"'t on your PATH yet. Add it with:\n'
    printf '     %secho '"'"'export PATH="$HOME/.local/bin:$PATH"'"'"' >> ~/.zshrc%s\n' "$BOLD" "$RESET"
    ;;
esac
printf '\n'
