#!/bin/zsh
# 构建 Localsocks.app（swiftc、iconutil 与本地 ad-hoc 签名）
set -euo pipefail

ROOT="${0:A:h}/.."
BUILD="$ROOT/build"
APP="$ROOT/dist/Localsocks.app"

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

ICONSET="$BUILD/Localsocks.iconset"
swiftc "$ROOT/macos/LogoGenerator.swift" -O -framework AppKit -o "$BUILD/logo-generator"
"$BUILD/logo-generator" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

swiftc "$ROOT/macos/Core.swift" "$ROOT/macos/LocalsocksApp.swift" \
  -O \
  -framework AppKit \
  -o "$APP/Contents/MacOS/Localsocks"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>localsocks</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>Localsocks</string>
    <key>CFBundleIdentifier</key>
    <string>com.localsocks.manager</string>
    <key>CFBundleName</key>
    <string>localsocks</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
