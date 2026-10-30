#!/bin/zsh
# 构建并安装到 /Applications（可重复执行，用来更新版本）
set -euo pipefail

ROOT="${0:A:h}/.."
APP_NAME="Localsocks"
DEST="/Applications/$APP_NAME.app"

echo "==> 1/5 构建"
"$ROOT/macos/build.sh" >/dev/null
SOURCE="$ROOT/dist/$APP_NAME.app"

echo "==> 2/5 校验签名"
codesign --verify --deep --strict "$SOURCE"

echo "==> 3/5 关闭正在运行的实例"
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1
pkill -f "$DEST/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "==> 4/5 复制到 /Applications"
rm -rf "$DEST"
cp -R "$SOURCE" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --verify --deep --strict "$DEST"

echo "==> 5/5 注册到 LaunchServices 并启动"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
open "$DEST"
echo "$DEST"
