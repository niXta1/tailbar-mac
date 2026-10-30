#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Tailbar"
BUILD_DIR="$APP_NAME.app"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/Contents/MacOS" "$BUILD_DIR/Contents/Resources"

echo "Compiling..."
# Keep the target below the host's newly-installed SDK/driver variant. The
# CommandLineTools image currently has a mismatched SwiftShims module cache;
# an explicit target plus a writable module cache makes rebuilds repeatable.
SWIFT_MODULE_CACHE="/private/tmp/tailbar-swift-cache"
mkdir -p "$SWIFT_MODULE_CACHE"
swiftc -O -target arm64-apple-macosx15.0 \
  -Xcc "-fmodules-cache-path=$SWIFT_MODULE_CACHE" \
  -framework AppKit -o "$BUILD_DIR/Contents/MacOS/$APP_NAME" Sources/*.swift

cp Resources/Info.plist "$BUILD_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUILD_DIR/Contents/Resources/AppIcon.icns"
# English is the development language; other .lproj folders hold translations.
cp -R Resources/*.lproj "$BUILD_DIR/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$BUILD_DIR/Contents/Resources/"

echo "Signing..."
codesign -s - --force --deep "$BUILD_DIR"

echo "Built $BUILD_DIR"
