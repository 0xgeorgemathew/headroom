#!/bin/zsh
# Renders assets/icon.svg into assets/AppIcon.icns on the macOS icon grid
# (824 pt artwork centred on a 1024 pt canvas, with a soft drop shadow).
# Needs rsvg-convert and ImageMagick (brew install librsvg imagemagick): NSImage
# drops the SVG blur filter, so it can't be used for the glow.
set -euo pipefail
cd "${0:A:h}/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rsvg-convert -w 824 -h 824 assets/icon.svg -o "$work/art.png"
magick -size 1024x1024 xc:none \
  \( "$work/art.png" -background 'rgba(0,0,0,0.35)' -shadow 100x14+0+10 \) -gravity center -geometry +0+6 -composite \
  "$work/art.png" -gravity center -composite "$work/icon_1024.png"
set=$work/AppIcon.iconset
mkdir "$set"
for s in 16 32 128 256 512; do
  magick "$work/icon_1024.png" -resize ${s}x${s} "$set/icon_${s}x${s}.png"
  magick "$work/icon_1024.png" -resize $((s*2))x$((s*2)) "$set/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$set" -o assets/AppIcon.icns
echo "wrote assets/AppIcon.icns"
