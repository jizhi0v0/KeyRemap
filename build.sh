#!/bin/sh
#
# 从源码构建 KeyRemap.app，产物在 build/KeyRemap.app。
# 只需要 Xcode 命令行工具（swiftc + iconutil + codesign），没有其他依赖。
#
#   sh build.sh              自动挑签名方式：有 Developer ID 就用它，否则 ad-hoc
#   SIGN_ID=- sh build.sh    强制 ad-hoc（本机自用足够）
#   SIGN_ID="Developer ID Application: 你的名字 (TEAMID)" sh build.sh
#
# 用 Developer ID 签名时会同时启用 hardened runtime 和安全时间戳 —— 这是提交
# 公证（notarization）的前提。本程序不需要任何 entitlement。
#
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/KeyRemap.app"

# 必须显式指定 deployment target。不指定的话 swiftc 会用当前 SDK 的版本，编出来的
# 二进制 minos 就等于构建机的系统版本，在更低版本的 macOS 上 dyld 直接拒绝加载，
# Finder 报的是 “is damaged and can't be opened”，极难联想到版本问题。
MIN_OS=14.0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[1/4] 编译（universal：arm64 + x86_64，最低 macOS $MIN_OS）"
for arch in arm64 x86_64; do
	swiftc -O -target "$arch-apple-macos$MIN_OS" "$ROOT/Sources/main.swift" \
		-o "$BUILD/KeyRemap-$arch" \
		-framework SwiftUI -framework AppKit -framework IOKit
done
lipo -create -output "$APP/Contents/MacOS/KeyRemap" "$BUILD/KeyRemap-arm64" "$BUILD/KeyRemap-x86_64"
rm -f "$BUILD/KeyRemap-arm64" "$BUILD/KeyRemap-x86_64"
echo "  架构: $(lipo -archs "$APP/Contents/MacOS/KeyRemap")"
echo "  minos: $(otool -l "$APP/Contents/MacOS/KeyRemap" | awk '/minos/{print $2; exit}')"

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
	<key>CFBundleShortVersionString</key><string>1.0.6</string>
	<key>CFBundleVersion</key><string>7</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "[4/4] 签名"
if [ "${SIGN_ID:-}" = "" ]; then
	# 自动挑：优先 Developer ID Application，找不到就退回 ad-hoc
	SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
		| sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
	[ -n "$SIGN_ID" ] || SIGN_ID="-"
fi

if [ "$SIGN_ID" = "-" ]; then
	echo "  ad-hoc 签名（本机自用可以，别人下载会被 Gatekeeper 拦）"
	codesign --force --sign - --identifier local.KeyRemap "$APP"
else
	echo "  $SIGN_ID"
	codesign --force --timestamp --options runtime \
		--sign "$SIGN_ID" --identifier local.KeyRemap "$APP"
fi
codesign --verify --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Authority|TeamIdentifier|Signature|Timestamp)' || true

echo
echo "构建完成：$APP"
echo "运行：open \"$APP\""
echo "安装：把它拖到 /Applications 或 ~/Applications"
