#!/bin/zsh
# Renders every UI state from fixtures (no live data) and composes the README images in media/.
# Uses the app's offscreen renderer: HeadroomApp --render <scenario|all> --out <dir>.
# Needs ImageMagick (brew install imagemagick).
set -euo pipefail
cd "${0:A:h}/.."
swift build --product HeadroomApp >/dev/null
raw=$(mktemp -d)
trap 'rm -rf "$raw"' EXIT
.build/debug/HeadroomApp --render all --out "$raw" >/dev/null
out=media
mkdir -p $out
bg='#0B0C0F'
font=/System/Library/Fonts/SFNS.ttf

# Palette-quantize PNGs when pngquant is available (keeps the repo light).
optimize() { command -v pngquant >/dev/null && pngquant --force --skip-if-larger --quality 80-95 --output "$1" "$1" || true; }


# Hero: Pace (dark) and Activity (light), side by side.
magick "$raw/pace-mockup-dark.png" "$raw/activity-all-24h-light.png" -resize x1400 \
  -background none -gravity north +append \
  -bordercolor none -border 40 -background "$bg" -flatten $out/hero.png
optimize $out/hero.png

# A labelled grid from scenario names.
grid() {  # grid <output> <columns> <scenario:label>...
  local target=$1 cols=$2; shift 2
  local tiles=()
  for spec in "$@"; do
    local file=${spec%%:*} label=${spec#*:}
    magick \( -size 560x64 xc:none -font $font -pointsize 26 -fill '#C9CBD2' -gravity center -annotate +0+4 "$label" \) \
      \( "$raw/$file.png" -resize 560x \) -background none -gravity north -append "$raw/tile-$file.png"
    tiles+=("$raw/tile-$file.png")
  done
  magick montage -font $font "${tiles[@]}" -tile ${cols}x -geometry +24+24 -gravity north -background "$bg" "$target"
  optimize "$target"
}

grid $out/pacing-states.png 4 \
  pace-plenty-dark:"Plenty available" pace-onpace-dark:"On pace" \
  pace-tight-projection-dark:"Getting tight" pace-verytight-dark:"Very tight"
grid $out/session-warnings.png 4 \
  pace-session-row-dark:"Session < 75%: a row" pace-session-amber-dark:"75%: amber banner" \
  pace-session-rose-dark:"90%: rose banner" pace-session-blocked-dark:"100%: blocked"
grid $out/faults.png 3 \
  pace-fault-offline-dark:"Offline" pace-fault-signedout-light:"Signed out" pace-fault-schema-dark:"Format changed" \
  pace-fault-outage-light:"Service outage" pace-fault-enterprise-dark:"Enterprise plan" pace-fault-cli-light:"CLI not found"
grid $out/callouts.png 4 \
  pace-cap-empty-dark:"Model cap reached" pace-cap-tight-light:"Model cap tighter" \
  pace-early-reset-dark:"Early reset" pace-credits-light:"Reset credits expiring"
grid $out/activity.png 3 \
  activity-all-7d-dark:"Activity · 7 days" activity-new-24h-light:"New only · 24 hours" activity-collecting-dark:"Collecting history"
grid $out/appearance.png 2 pace-mockup-light:"Light" pace-mockup-dark:"Dark"

magick "$raw/menubar.png" -resize 1020x $out/menubar.png; optimize $out/menubar.png
magick "$raw/share-card-claude.png" -resize 1600x $out/share-card.png; optimize $out/share-card.png
magick "$raw/share-snapshot.png" -resize 1600x $out/share-snapshot.png; optimize $out/share-snapshot.png
cp "$raw/share-text.txt" $out/share-text.txt

# Animated tour of the pacing states.
frames=()
for s in plenty onpace tight-projection verytight exhausted session-amber session-blocked fault-offline; do
  magick "$raw/pace-$s-dark.png" -resize 384x -background "$bg" -gravity north -extent 384x900 "$raw/frame-$s.png"
  frames+=("$raw/frame-$s.png")
done
magick -delay 160 -loop 0 "${frames[@]}" -layers Optimize $out/states.gif

ls -la $out
