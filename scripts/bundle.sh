#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

INFO_PLIST="${LOUDER_INFO_PLIST:-$ROOT/Resources/Info.plist}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Louder.app"

if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: Info.plist not found at $INFO_PLIST" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
echo "==> Building Louder $VERSION"

if [[ "${LOUDER_NATIVE_ONLY:-0}" == "1" ]]; then
  echo "warning: LOUDER_NATIVE_ONLY=1, building for the native architecture only" >&2
  ARCH_FLAGS=()
else
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release --product Louder ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --product Louder ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

BINARY="$BIN_DIR/Louder"
if [[ ! -x "$BINARY" ]]; then
  echo "error: built executable not found at $BINARY" >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Louder"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp "$ROOT/Brand/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Brand/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
cp "$ROOT/Brand/MenuBarIcon@2x.png" "$APP/Contents/Resources/MenuBarIcon@2x.png"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Louder")"
echo "==> Architectures: $ARCHS"
if [[ "${LOUDER_NATIVE_ONLY:-0}" != "1" && ( " $ARCHS " != *" arm64 "* || " $ARCHS " != *" x86_64 "* ) ]]; then
  echo "error: expected a universal binary (arm64 x86_64), got: $ARCHS" >&2
  exit 1
fi

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Built $APP"
