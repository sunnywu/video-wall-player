#!/usr/bin/env bash
#
# Build a shareable macOS app bundle that embeds VLC's runtime files.
#
set -euo pipefail

APP_NAME="Video Wall Player"
BUNDLE_ID="${BUNDLE_ID:-com.sunnywu.videowallplayer}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VLC_APP="${VLC_APP:-/Applications/VLC.app}"
VLC_MACOS="$VLC_APP/Contents/MacOS"
BUILD_DIR="$ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
DIST_DIR="$ROOT/dist"
APP_BUILD="$BUILD_DIR/sixplayer.app"
APP_DIST="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
DMG_ROOT="$BUILD_DIR/dmg-root"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
PLIST="$APP_DIST/Contents/Info.plist"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

require_dir() {
  if [ ! -d "$1" ]; then
    echo "error: missing required directory: $1" >&2
    exit 1
  fi
}

require_command xcodebuild
require_command ditto
require_command codesign
require_command hdiutil
require_command /usr/libexec/PlistBuddy
require_dir "$VLC_MACOS/lib"
require_dir "$VLC_MACOS/plugins"

mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "[package] building app..."
xcodebuild -project "$ROOT/sixplayer.xcodeproj" \
  -scheme sixplayer \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" >/dev/null

echo "[package] assembling $APP_NAME.app..."
rm -rf "$APP_DIST" "$ZIP_PATH" "$DMG_PATH" "$DMG_ROOT"
ditto "$APP_BUILD" "$APP_DIST"

mkdir -p "$APP_DIST/Contents/Frameworks" "$APP_DIST/Contents/Resources/vlc"
ditto "$VLC_MACOS/lib" "$APP_DIST/Contents/Frameworks"
ditto "$VLC_MACOS/plugins" "$APP_DIST/Contents/Resources/vlc/plugins"
if [ -d "$VLC_MACOS/share" ]; then
  ditto "$VLC_MACOS/share" "$APP_DIST/Contents/Resources/vlc/share"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"

xattr -cr "$APP_DIST" 2>/dev/null || true

echo "[package] signing locally..."
codesign --force --deep --sign - "$APP_DIST" >/dev/null
codesign --verify --deep --strict "$APP_DIST"

echo "[package] creating zip..."
(
  cd "$DIST_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP_PATH"
)

echo "[package] creating dmg..."
mkdir -p "$DMG_ROOT"
ditto "$APP_DIST" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
cat >"$DMG_ROOT/README.txt" <<EOF
Install:
1. Drag "$APP_NAME.app" into Applications.
2. Open it from Applications.

This build embeds VLC runtime files, so VLC does not need to be installed separately.
If macOS blocks the first launch because the app is not notarized, right-click the app and choose Open.
EOF
if hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH" >/dev/null; then
  :
else
  echo "[package] warning: DMG creation failed; zip and app bundle are still ready." >&2
fi

echo "[package] done:"
du -sh "$APP_DIST" "$ZIP_PATH" "$DMG_PATH" 2>/dev/null || true
