#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_PATH="$PROJECT_DIR/dist/InputMate.app"
DMG_PATH="$PROJECT_DIR/dist/InputMate-$VERSION.dmg"
STAGING_DIR="$(mktemp -d /private/tmp/InputMate-dmg.XXXXXX)"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$PROJECT_DIR/scripts/build-app.sh"

ditto "$APP_PATH" "$STAGING_DIR/InputMate.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "InputMate $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"
echo "$DMG_PATH"
