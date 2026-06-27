#!/bin/bash
#
# make-dmg.sh — builds SnapShotKit.app (via make-app.sh) and packages it into a
# distributable SnapShotKit.dmg with a drag-to-Applications layout.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="SnapShotKit"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
DIST_DIR="$SCRIPT_DIR/dist"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
STAGING="$(mktemp -d)"

# 1. Ensure a fresh app bundle exists.
echo "==> Building app bundle…"
bash "$SCRIPT_DIR/make-app.sh" >/dev/null
if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: $APP_BUNDLE not found after build." >&2
    exit 1
fi

# 2. Stage the .app plus an /Applications symlink for drag-install.
echo "==> Staging disk image contents…"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 3. Build a compressed DMG.
echo "==> Creating DMG…"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGING"

echo ""
echo "Done. Disk image: $DMG_PATH"
echo ""
echo "NOTE: the app is ad-hoc signed (not notarized). On another Mac, Gatekeeper"
echo "will warn on first open — right-click the app > Open > Open to bypass, or"
echo "notarize it with an Apple Developer account for a warning-free install."
