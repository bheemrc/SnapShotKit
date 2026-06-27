#!/bin/bash
#
# make-app.sh — builds SnapShotKit and wraps the executable into SnapShotKit.app
# so that macOS TCC (Screen Recording permission) associates the grant with a
# stable bundle identifier (com.snapshotkit.app) instead of a bare binary.
#
set -euo pipefail

# Resolve the directory this script lives in (the package root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="SnapShotKit"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
INFO_PLIST_SRC="$SCRIPT_DIR/Sources/SnapShotKit/Info.plist"

echo "==> Building $APP_NAME (release)…"
swift build -c release

BUILT_BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -f "$BUILT_BINARY" ]]; then
    echo "ERROR: built binary not found at: $BUILT_BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app…"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILT_BINARY" "$MACOS_DIR/$APP_NAME"
cp "$INFO_PLIST_SRC" "$CONTENTS/Info.plist"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "==> Ad-hoc codesigning…"
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Done. Built: $APP_BUNDLE"
echo ""
echo "First-run setup:"
echo "  1. Open the app:    open \"$APP_BUNDLE\""
echo "  2. Trigger a capture (menu-bar camera icon > Capture, or ⌘⇧\\)."
echo "  3. macOS will prompt for Screen Recording. Approve SnapShotKit under:"
echo "     System Settings > Privacy & Security > Screen Recording"
echo "  4. Quit and reopen SnapShotKit so the new permission takes effect."
echo ""
