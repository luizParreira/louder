#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Louder.app"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found; run scripts/bundle.sh first" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD_DIR/Louder-$VERSION.dmg"
ZIP="$BUILD_DIR/Louder-$VERSION.zip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Creating $DMG"
cp -R "$APP" "$STAGE/Louder.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Louder" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo "==> Creating $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Checksums"
cd "$BUILD_DIR"
shasum -a 256 "Louder-$VERSION.dmg" > "Louder-$VERSION.dmg.sha256"
shasum -a 256 "Louder-$VERSION.zip" > "Louder-$VERSION.zip.sha256"

echo "==> Stable-named assets"
cp "Louder-$VERSION.zip" Louder.zip
shasum -a 256 Louder.zip > Louder.zip.sha256

ls -l "$BUILD_DIR"/Louder*.dmg "$BUILD_DIR"/Louder*.zip "$BUILD_DIR"/Louder*.sha256
