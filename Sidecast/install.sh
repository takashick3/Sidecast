#!/bin/zsh
# build.sh（Release ビルド + dmg）を実行し、/Applications/Sidecast.app に入れて起動し直す。
# ログイン項目（SMAppService）は安定したパスにあるアプリが前提なので、常用はこのコピーから行う。
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
APP=build/Build/Products/Release/Sidecast.app
pkill -x Sidecast 2>/dev/null || true
sleep 1
rm -rf /Applications/Sidecast.app
ditto "$APP" /Applications/Sidecast.app
open /Applications/Sidecast.app
echo "installed: /Applications/Sidecast.app ($(defaults read /Applications/Sidecast.app/Contents/Info.plist CFBundleShortVersionString))"
