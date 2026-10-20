#!/bin/bash
# Packages the built app as a zip (and a DMG) in ./dist. With a Developer ID identity and a
# notarytool keychain profile it also notarizes and staples; without them it says so plainly.
#
#   scripts/package.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=forma-notary scripts/package.sh
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials forma-notary --apple-id you@example.com --team-id TEAMID
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.0.0}"
STAGE="${STAGE_DIR:-$HOME/Library/Caches/Forma/build}"
DIST="$ROOT/dist"

SIGN_IDENTITY="${SIGN_IDENTITY:--}" VERSION="$VERSION" scripts/build.sh
APP="$STAGE/Forma.app"
mkdir -p "$DIST"

ZIP="$DIST/Forma-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --noextattr "$APP" "$ZIP"

if [ "${SIGN_IDENTITY:--}" != "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarizing"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent --noextattr "$APP" "$ZIP"
  NOTARIZED=yes
else
  NOTARIZED=no
fi

DMG="$DIST/Forma-$VERSION.dmg"
rm -f "$DMG"
TMP="$(mktemp -d)"
ditto --noextattr "$APP" "$TMP/Forma.app"
ln -s /Applications "$TMP/Applications"
hdiutil create -quiet -volname "Forma" -srcfolder "$TMP" -ov -format UDZO "$DMG"
rm -rf "$TMP"

echo "✓ $ZIP"
echo "✓ $DMG"
if [ "$NOTARIZED" = no ]; then
  echo "  Note: ad-hoc signed and NOT notarized. It runs on this Mac; on other Macs Gatekeeper"
  echo "  will block it until it is signed with a Developer ID and notarized (see docs/RELEASE.md)."
fi
