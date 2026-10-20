#!/bin/bash
# Builds Forma.app (with its Finder Sync extension) into ./build using only the
# Swift toolchain — Xcode is optional. Signs ad-hoc unless SIGN_IDENTITY is set.
#
#   scripts/build.sh                       # release build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build.sh
#   BUNDLE_ID=com.example.forma VERSION=1.0.1 BUILD=2 scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
BUNDLE_ID="${BUNDLE_ID:-app.forma.mac}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MIN_MACOS="14.0"
ARCH="$(uname -m)"
OUT="$ROOT/build"
# Assemble and sign outside the project: iCloud/File Provider folders (like a synced
# Desktop) attach Finder metadata to bundles, which codesign rejects.
STAGE="${STAGE_DIR:-$HOME/Library/Caches/Forma/build}"
APP="$STAGE/Forma.app"
APPEX="$APP/Contents/PlugIns/FormaFinderSync.appex"

echo "▸ Building Forma ($CONFIG, $ARCH)"
swift build -c "$CONFIG" --product Forma
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"
cp "$BIN/Forma" "$APP/Contents/MacOS/Forma"

render_plist() { # template output
  sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" -e "s/\$(VERSION)/$VERSION/g" -e "s/\$(BUILD)/$BUILD/g" "$1" > "$2"
  plutil -lint -s "$2"
}
render_plist Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Generating app icon"
  ICONSET="$STAGE/AppIcon.iconset"
  rm -rf "$ICONSET"
  swift scripts/make-icon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Building Finder Sync extension"
SDK="$(xcrun --show-sdk-path)"
OPT=$([ "$CONFIG" = "release" ] && echo "-O" || echo "-Onone -g")
swiftc $OPT -swift-version 5 -module-name FormaFinderSync \
  -target "$ARCH-apple-macos$MIN_MACOS" -sdk "$SDK" \
  -parse-as-library -application-extension \
  -Xlinker -application_extension -Xlinker -e -Xlinker _NSExtensionMain \
  -framework FinderSync -framework Cocoa \
  Extensions/FinderSync/FinderSync.swift -o "$APPEX/Contents/MacOS/FormaFinderSync"
render_plist Extensions/FinderSync/Info.plist "$APPEX/Contents/Info.plist"

xattr -cr "$APP"
echo "▸ Signing ($([ "$SIGN_IDENTITY" = "-" ] && echo "ad-hoc" || echo "$SIGN_IDENTITY"))"
TIMESTAMP=$([ "$SIGN_IDENTITY" = "-" ] && echo "" || echo "--timestamp")
codesign --force --options runtime $TIMESTAMP --entitlements Extensions/FinderSync/FinderSync.entitlements \
  --sign "$SIGN_IDENTITY" "$APPEX"
codesign --force --options runtime $TIMESTAMP --entitlements Resources/Forma.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# Convenience copy inside the project (metadata stripped so it stays valid where possible).
rm -rf "$OUT/Forma.app"
ditto --noextattr --noqtn "$APP" "$OUT/Forma.app"

echo "✓ $APP"
echo "  copy: $OUT/Forma.app"
du -sh "$APP" | awk '{print "  size: "$1}'
