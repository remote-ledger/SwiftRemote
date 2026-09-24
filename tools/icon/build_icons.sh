#!/usr/bin/env bash
#
# Regenerates every SwiftRemote app icon from the vector master defined below.
#
#   tools/icon/build_icons.sh
#
# Writes the SVG masters next to this script and rasterises them straight into
# the Android res/, ios/, assets/, web/ and fastlane/ trees, so
# `flutter_launcher_icons` never has to run to refresh the icon. Needs headless
# Chrome (google-chrome or chromium) to rasterise and ffmpeg to re-encode;
# everything else is plain shell.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

chrome=""
for c in google-chrome google-chrome-stable chromium chromium-browser; do
  command -v "$c" >/dev/null 2>&1 && chrome="$c" && break
done
[ -n "$chrome" ] || { echo "need google-chrome or chromium on PATH" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "need ffmpeg on PATH" >&2; exit 1; }

# ---------------------------------------------------------------- the artwork
#
# A handset-style remote tilted 28 degrees, firing three infrared arcs out of
# its emitter. Drawn in a local 1024-unit space whose bounding box is
# 286 x 681 centred on (0, 24.5); every variant below reuses it at a different
# scale, so the proportions stay identical across the whole icon set.

# Power glyph and buttons, punched out of the shell so the background shows through.
knockouts() {
  cat <<'EOF'
      <g fill="#000">
        <path d="M 29.8 12.4 A 52 52 0 1 1 -29.8 12.4" fill="none" stroke="#000" stroke-width="22" stroke-linecap="round"/>
        <rect x="-11" y="-23" width="22" height="54" rx="11"/>
        <circle cx="-55" cy="190" r="21"/>
        <circle cx="55" cy="190" r="21"/>
        <circle cx="-55" cy="268" r="21"/>
        <circle cx="55" cy="268" r="21"/>
      </g>
EOF
}

# art <shell-fill> <beam-fill> <mask-id>
art() {
  cat <<EOF
    <mask id="$3">
      <rect x="-140" y="-105" width="280" height="470" rx="92" fill="#fff"/>
$(knockouts)
    </mask>
    <rect x="-140" y="-105" width="280" height="470" rx="92" fill="$1" mask="url(#$3)"/>
    <rect x="-42" y="-84" width="84" height="26" rx="13" fill="$2"/>
    <g fill="none" stroke="$2" stroke-linecap="round">
      <path d="M -49.5 -169.5 A 70 70 0 0 1 49.5 -169.5" stroke-width="28"/>
      <path d="M -88.4 -208.4 A 125 125 0 0 1 88.4 -208.4" stroke-width="30"/>
      <path d="M -127.3 -247.3 A 180 180 0 0 1 127.3 -247.3" stroke-width="32"/>
    </g>
EOF
}

gradients() {
  cat <<'EOF'
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#2D9BF0"/>
      <stop offset="0.55" stop-color="#1668D8"/>
      <stop offset="1" stop-color="#0B3B96"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.28" cy="0.2" r="0.75">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.16"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="beam" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#FF7A3D"/>
      <stop offset="1" stop-color="#FFD166"/>
    </linearGradient>
    <linearGradient id="shell" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#DBE6F4"/>
    </linearGradient>
    <filter id="cast" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#04205A" flood-opacity="0.34"/>
    </filter>
EOF
}

# Scales: ADAPT keeps the art inside Android's 66dp guaranteed circle (and the
# same safe zone a maskable web icon needs); FULL fills a standalone icon, which
# no launcher crops. Verified with tools/icon/check_safe_zone.html.
ADAPT=0.87
FULL=1.15

open_svg() { echo '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'; }
# place <scale> [shadow]  - centres the art on the canvas, nudged along the tilt
# so the heavy shell and the light arcs balance optically rather than
# geometrically. Pass shadow=no for the monochrome layer, which Android tints by
# alpha alone and so must stay perfectly flat.
place() {
  local shadow=' filter="url(#cast)"'
  [ "${2:-yes}" = no ] && shadow=''
  echo "  <g$shadow><g transform=\"translate(518,506) rotate(28) scale($1) translate(0,-24.5)\">"
}
close_place() { echo '  </g></g>'; }

# ------------------------------------------------------------------ the files

svg_background() {
  open_svg
  echo '  <defs>'; gradients; echo '  </defs>'
  echo '  <rect width="1024" height="1024" fill="url(#bg)"/>'
  echo '  <rect width="1024" height="1024" fill="url(#glow)"/>'
  echo '</svg>'
}

svg_foreground() {
  open_svg
  echo '  <defs>'; gradients; echo '  </defs>'
  place "$ADAPT"; art 'url(#shell)' 'url(#beam)' 'fgMask'; close_place
  echo '</svg>'
}

svg_monochrome() {
  open_svg
  place "$ADAPT" no; art '#FFFFFF' '#FFFFFF' 'monoMask'; close_place
  echo '</svg>'
}

# svg_composed <rounded|square> <scale>
svg_composed() {
  local rx=0; [ "$1" = rounded ] && rx=230
  open_svg
  echo '  <defs>'
  gradients
  echo "    <clipPath id=\"plate\"><rect width=\"1024\" height=\"1024\" rx=\"$rx\"/></clipPath>"
  echo '  </defs>'
  echo '  <g clip-path="url(#plate)">'
  echo '  <rect width="1024" height="1024" fill="url(#bg)"/>'
  echo '  <rect width="1024" height="1024" fill="url(#glow)"/>'
  place "$2"; art 'url(#shell)' 'url(#beam)' 'cpMask'; close_place
  echo '  </g>'
  echo '</svg>'
}

svg_background   > "$here/background.svg"
svg_foreground   > "$here/foreground.svg"
svg_monochrome   > "$here/monochrome.svg"
svg_composed rounded "$FULL"  > "$here/icon.svg"
svg_composed square  "$ADAPT" > "$here/maskable.svg"
# iOS rounds the corners itself, so it takes the same art on a full-bleed plate.
svg_composed square  "$FULL"  > "$here/ios.svg"

# ------------------------------------------------- Android background layer
#
# The background is a plain two-gradient wash, so it ships as a vector drawable
# rather than five PNGs: ~180 KB less APK and crisp at any density. Keep these
# stops in step with the #bg and #glow gradients above - background.svg is the
# same wash, kept as the preview of this layer.
write_vector_background() {
  local out="$root/android/app/src/main/res/drawable/ic_launcher_background.xml"
  mkdir -p "$(dirname "$out")"
  cat > "$out" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by tools/icon/build_icons.sh - edit the gradients there. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
  <path android:pathData="M0,0h108v108h-108z">
    <aapt:attr name="android:fillColor">
      <gradient
          android:type="linear"
          android:startX="0" android:startY="0"
          android:endX="108" android:endY="108">
        <item android:offset="0" android:color="#2D9BF0"/>
        <item android:offset="0.55" android:color="#1668D8"/>
        <item android:offset="1" android:color="#0B3B96"/>
      </gradient>
    </aapt:attr>
  </path>
  <path android:pathData="M0,0h108v108h-108z">
    <aapt:attr name="android:fillColor">
      <gradient
          android:type="radial"
          android:centerX="30.2" android:centerY="21.6"
          android:gradientRadius="81">
        <item android:offset="0" android:color="#29FFFFFF"/>
        <item android:offset="1" android:color="#00FFFFFF"/>
      </gradient>
    </aapt:attr>
  </path>
</vector>
EOF
  echo "  ${out#$root/}"
}

# --------------------------------------------------------------- rasterising

# Every re-encode here is pixel-for-pixel lossless - only the PNG filtering
# changes. Which filter deflates smallest swings by 20% between a flat
# silhouette and a gradient and no single choice wins everywhere, so try the
# lot and keep the smallest.
reencode() { # reencode <png> <pix_fmt> <may-keep-original>
  local png="$1" fmt="$2" keep="$3" best="" tmp pred
  for pred in none sub up avg paeth mixed; do
    tmp="$(mktemp)".png
    if ffmpeg -y -loglevel error -i "$png" -pix_fmt "$fmt" -compression_level 100 \
         -pred "$pred" "$tmp" 2>/dev/null && [ -s "$tmp" ] &&
       { [ -z "$best" ] || [ "$(wc -c < "$tmp")" -lt "$(wc -c < "$best")" ]; }; then
      rm -f "$best"; best="$tmp"
    else
      rm -f "$tmp"
    fi
  done
  [ -n "$best" ] || return 0
  if [ "$keep" = yes ] && [ "$(wc -c < "$png")" -le "$(wc -c < "$best")" ]; then
    rm -f "$best"          # Chrome already encoded it smaller
  else
    mv "$best" "$png"
  fi
}

squeeze() { reencode "$1" rgba yes; }

# Chrome always writes RGBA. The App Store rejects an icon that so much as
# carries an alpha channel (ITMS-90717), so iOS PNGs drop theirs - which is not
# optional, hence no keeping Chrome's original here.
flatten() { reencode "$1" rgb24 no; }

render() { # render <src.svg> <out.png> <size>
  local src="$1" out="$2" size="$3" tmp
  tmp="$(mktemp -d)"
  sed -E "s|(<svg[^>]*)width=\"1024\"|\1width=\"$size\"|; s|(<svg[^>]*)height=\"1024\"|\1height=\"$size\"|" \
    "$src" > "$tmp/in.svg"
  mkdir -p "$(dirname "$out")"
  "$chrome" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --default-background-color=00000000 --force-device-scale-factor=1 \
    --screenshot="$out" --window-size="$size,$size" "$tmp/in.svg" >/dev/null 2>&1
  rm -rf "$tmp"
  squeeze "$out"
  echo "  ${out#$root/} (${size}px)"
}

render_opaque() { # render_opaque <src.svg> <out.png> <size>
  render "$1" "$2" "$3"
  flatten "$2"
}

echo "Android launcher layers"
# Adaptive layers are a 108dp canvas at each density; legacy mipmaps are 48dp.
for d in "mdpi 108 48" "hdpi 162 72" "xhdpi 216 96" "xxhdpi 324 144" "xxxhdpi 432 192"; do
  set -- $d
  render "$here/foreground.svg" "$root/android/app/src/main/res/drawable-$1/ic_launcher_foreground.png" "$2"
  render "$here/monochrome.svg" "$root/android/app/src/main/res/drawable-$1/ic_launcher_monochrome.png" "$2"
  render "$here/icon.svg"       "$root/android/app/src/main/res/mipmap-$1/ic_launcher.png" "$3"
done
write_vector_background

echo "flutter_launcher_icons sources"
# logo.png doubles as the in-app About logo (shown at 88dp) and as the legacy
# mipmap source, so 384px covers the densest screen without bloating the APK.
render "$here/icon.svg"       "$root/assets/images/logo.png" 384
render "$here/foreground.svg" "$root/assets/images/icon_foreground.png" 1024
render "$here/background.svg" "$root/assets/images/icon_background.png" 512
render "$here/monochrome.svg" "$root/assets/images/icon_mono.png" 1024
render_opaque "$here/ios.svg" "$root/assets/images/icon_ios.png" 1024

echo "iOS app icon"
# One entry per file in ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json,
# sized point-size x scale. Keep the two in step if Contents.json ever changes.
for e in "20x20@1x 20" "20x20@2x 40" "20x20@3x 60" \
         "29x29@1x 29" "29x29@2x 58" "29x29@3x 87" \
         "40x40@1x 40" "40x40@2x 80" "40x40@3x 120" \
         "60x60@2x 120" "60x60@3x 180" \
         "76x76@1x 76" "76x76@2x 152" "83.5x83.5@2x 167" \
         "1024x1024@1x 1024"; do
  set -- $e
  render_opaque "$here/ios.svg" \
    "$root/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-$1.png" "$2"
done

echo "Store listing and web"
render "$here/icon.svg"     "$root/fastlane/metadata/android/en-US/images/icon.png" 512
render "$here/icon.svg"     "$root/web/favicon.png" 32
render "$here/icon.svg"     "$root/web/icons/Icon-192.png" 192
render "$here/icon.svg"     "$root/web/icons/Icon-512.png" 512
render "$here/maskable.svg" "$root/web/icons/Icon-maskable-192.png" 192
render "$here/maskable.svg" "$root/web/icons/Icon-maskable-512.png" 512
