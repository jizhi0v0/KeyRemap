#!/bin/sh
#
# 从源码构建 KeyRemap.app，产物在 build/KeyRemap.app。
# 只需要 Xcode 命令行工具（swiftc + iconutil + codesign），没有其他依赖。
#
#   sh build.sh
#
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/KeyRemap.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[1/4] 编译"
swiftc -O "$ROOT/Sources/main.swift" -o "$APP/Contents/MacOS/KeyRemap" \
	-framework SwiftUI -framework AppKit -framework IOKit

echo "[2/4] 生成图标"
rm -rf "$BUILD/KeyRemap.iconset"
swift "$ROOT/Tools/makeicon.swift" "$BUILD/KeyRemap.iconset" >/dev/null
iconutil -c icns "$BUILD/KeyRemap.iconset" -o "$APP/Contents/Resources/KeyRemap.icns"

echo "[3/4] 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>KeyRemap</string>
	<key>CFBundleIdentifier</key><string>local.KeyRemap</string>
	<key>CFBundleName</key><string>KeyRemap</string>
	<key>CFBundleIconFile</key><string>KeyRemap</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "[4/4] 临时签名"
codesign --force --sign - --identifier local.KeyRemap "$APP"
codesign --verify --strict "$APP"

echo
echo "构建完成：$APP"
echo "运行：open \"$APP\""
echo "安装：把它拖到 /Applications 或 ~/Applications"
