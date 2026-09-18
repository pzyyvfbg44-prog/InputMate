#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/InputMate.app"
STAGING_DIR="$DIST_DIR/.InputMate.app.staging"
CONTENTS_DIR="$STAGING_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$DIST_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
trap 'rm -rf "$STAGING_DIR"' EXIT

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
clang \
  -fobjc-arc \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -Wl,-dead_strip \
  -arch arm64 \
  -arch x86_64 \
  -mmacosx-version-min=13.0 \
  -isysroot "$SDK_PATH" \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework ServiceManagement \
  "$PROJECT_DIR/Native/main.m" \
  -o "$MACOS_DIR/InputMate"

cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/InputMate.icns" "$RESOURCES_DIR/InputMate.icns"

# Keep a stable designated requirement in development builds so macOS privacy
# permissions survive recompilation even without a Developer ID certificate.
plutil -lint "$CONTENTS_DIR/Info.plist"

codesign \
  --force \
  --deep \
  --sign - \
  --requirements '=designated => identifier "dev.inputmate.app"' \
  "$STAGING_DIR"

codesign --verify --deep --strict "$STAGING_DIR"
rm -rf "$APP_DIR"
mv "$STAGING_DIR" "$APP_DIR"
trap - EXIT
echo "$APP_DIR"
