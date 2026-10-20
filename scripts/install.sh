#!/bin/bash
# Installs build/Forma.app into ~/Applications (or $INSTALL_DIR), registers it with
# Launch Services, the Services menu and pluginkit, then launches it.
# It does not change any system or privacy settings: enabling the Finder extension and
# granting Accessibility remain your choice in System Settings.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${STAGE_DIR:-$HOME/Library/Caches/Forma/build}/Forma.app"
[ -d "$SRC" ] || SRC="$ROOT/build/Forma.app"
DEST_DIR="${INSTALL_DIR:-$HOME/Applications}"
DEST="$DEST_DIR/Forma.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$SRC" ] || { echo "Run scripts/build.sh first."; exit 1; }
mkdir -p "$DEST_DIR"

if pgrep -xq Forma; then
  echo "▸ Quitting running Forma"
  osascript -e 'tell application id "'"$(defaults read "$SRC/Contents/Info" CFBundleIdentifier)"'" to quit' >/dev/null 2>&1 || pkill -x Forma || true
  sleep 1
fi

echo "▸ Installing to $DEST"
rm -rf "$DEST"
ditto --noextattr --noqtn "$SRC" "$DEST"
codesign --verify --deep --strict "$DEST"

echo "▸ Registering"
"$LSREGISTER" -f -R -trusted "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/FormaFinderSync.appex" || true
/System/Library/CoreServices/pbs -update || true

echo "▸ Launching"
open "$DEST"

cat <<'MSG'

✓ Forma is installed.

Finish setup (each step is optional):
  1. Finder menu:   System Settings › General › Login Items & Extensions › Finder Extensions › Forma
  2. Shortcut:      select a file in Finder and press ⌥⌘K (allow "Forma wants to control Finder" once)
  3. Shift+right-click: Forma › Settings › Shortcuts › Enable… (grants Accessibility)
  4. Services:      right-click a file › Services (or Quick Actions) › Open in Forma
MSG
