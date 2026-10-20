#!/bin/bash
# Regenerates every image in docs/images from the real app (no hand-edited mockups).
# Requires a built app: scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="${STAGE_DIR:-$HOME/Library/Caches/Forma/build}/Forma.app"
F="$APP/Contents/MacOS/Forma"
[ -x "$F" ] || { echo "Build first: scripts/build.sh"; exit 1; }

OUT="$ROOT/docs/images"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
A="swift scripts/readme-assets.swift"

echo "▸ Sample content"
$A samples "$WORK/samples" >/dev/null
S="$WORK/samples"
"$F" --convert "$S/Launch Plan.md" --to pdf >/dev/null
"$F" --convert "$S/Launch Plan.md" --to docx >/dev/null
cp "$S/Lake at Dusk.png" "$S/Screenshot 2026-10-20 at 09.41.12.png"

echo "▸ Wheel states"
"$F" --snapshot-wheel "$S/Lake at Dusk.png" --out "$WORK/wheel-light.png" --transparent --hover 0 >/dev/null
"$F" --snapshot-wheel "$S/Lake at Dusk.png" --out "$WORK/wheel-dark.png" --transparent --dark --hover 0 >/dev/null
"$F" --snapshot-wheel "$S/Launch Plan.docx" --out "$WORK/wheel-docx.png" --transparent >/dev/null
"$F" --snapshot-wheel "$S/Launch Plan.pdf" --out "$WORK/wheel-pdf-dark.png" --transparent --dark >/dev/null
"$F" --snapshot-wheel "$S/Lake at Dusk.png" --out "$WORK/wheel-working.png" --transparent --phase working >/dev/null
"$F" --snapshot-wheel "$S/Lake at Dusk.png" --out "$WORK/wheel-done.png" --transparent --phase done >/dev/null
"$F" --snapshot-wheel "$S/Lake at Dusk.png" --out "$WORK/wheel-options.png" --transparent --phase options >/dev/null

echo "▸ Editors"
"$F" --snapshot-editor "$S/Lake at Dusk.png" --out "$WORK/ed-image.png" --demo --width 1200 --height 760 >/dev/null
"$F" --snapshot-editor "$S/Launch Plan.pdf" --out "$WORK/ed-pdf.png" --demo --dark --width 1200 --height 760 >/dev/null
"$F" --snapshot-editor "$S/Launch Plan.md" --out "$WORK/ed-md.png" --width 1200 --height 760 >/dev/null

echo "▸ Compositing"
ICON="$WORK/icon.png"
swift scripts/make-icon.swift "$WORK/iconset" >/dev/null && cp "$WORK/iconset/icon_256x256@2x.png" "$ICON"
$A hero "$ICON" "$WORK/wheel-light.png" "$WORK/hero.png" >/dev/null
sips -s format jpeg -s formatOptions 88 "$WORK/hero.png" --out "$OUT/hero.jpg" >/dev/null
$A pair "$WORK/wheel-light.png" "$WORK/wheel-dark.png" "$OUT/wheel-light-dark.png" >/dev/null
$A flow "$WORK/wheel-light.png" "$WORK/wheel-working.png" "$WORK/wheel-done.png" "$OUT/flow.png" >/dev/null
$A window "$WORK/ed-image.png" "$OUT/editor-image.png" >/dev/null
$A window "$WORK/ed-pdf.png" "$OUT/editor-pdf.png" --dark >/dev/null
$A window "$WORK/ed-md.png" "$OUT/editor-markdown.png" >/dev/null
cp "$WORK/wheel-docx.png" "$OUT/wheel-docx.png"
cp "$WORK/wheel-pdf-dark.png" "$OUT/wheel-pdf-dark.png"
cp "$WORK/wheel-options.png" "$OUT/wheel-options.png"
cp "$ICON" "$OUT/icon.png"

# Keep the repository light: downscale and re-encode with sips.
for f in "$OUT"/*.png; do
  w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
  [ "$w" -gt 2400 ] && sips --resampleWidth 2400 "$f" >/dev/null
done
ls -la "$OUT"
