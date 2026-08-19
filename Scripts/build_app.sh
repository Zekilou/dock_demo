#!/bin/bash
# 构建并打包 DockPopover.app（SPM 编译 + 组装 App Bundle + 固定证书签名）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_NAME="DockPopover"
BUNDLE_ID="com.zekiwithcat.DockPopover"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> swift build -c release --disable-sandbox"
swift build -c release --disable-sandbox

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "==> codesign (固定自签名证书: DockPopover Dev)"
# 用固定证书签名，保证 TCC 辅助功能授权不会因签名变化而失效
KC="$ROOT/.keys/dp.keychain"
security unlock-keychain -p "dpdev" "$KC" 2>/dev/null || true
codesign --force --sign "DockPopover Dev" --keychain "$KC" "$APP"

echo "==> 完成: $(pwd)/$APP"
