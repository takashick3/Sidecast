#!/bin/zsh
# Release ビルドと配布用 dmg の作成。
#   出力: build/Build/Products/Release/Sidecast.app
#         dist/Sidecast-<version>.dmg  （Sidecast.app / README.md / README.txt / LICENSE / Applications へのシンボリックリンク）
set -euo pipefail
cd "$(dirname "$0")"
ROOT=..
xcodegen generate
xcodebuild -project Sidecast.xcodeproj -scheme Sidecast -configuration Release -derivedDataPath build build -quiet 2>&1 \
  | grep -vE "CoreSimulator|DVTPlugIn|IDERunDestination|matching destinations|platform:macOS|^Details|^\s*$" || true
APP=build/Build/Products/Release/Sidecast.app
[ -d "$APP" ] || { echo "build failed: $APP not found" >&2; exit 1; }
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Sidecast.app"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$STAGE/"
cp dmg-README.txt "$STAGE/README.txt"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/Sidecast-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Sidecast $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
echo "app: $APP ($VERSION)"
echo "dmg: $DMG ($(du -h "$DMG" | cut -f1))"
