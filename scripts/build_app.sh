#!/bin/bash
# Builds dist/Claudophobia.app from the SPM executable.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claudophobia"
BUNDLE_ID="com.claudophobia.app"
VERSION="0.1.0"

echo "▸ swift build (release)"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
APP_DIR="dist/${APP_NAME}.app"
RES_DIR="${APP_DIR}/Contents/Resources"
MACOS_DIR="${APP_DIR}/Contents/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$RES_DIR" "$MACOS_DIR"

echo "▸ copying binary"
cp "$BIN_PATH" "$MACOS_DIR/${APP_NAME}"

echo "▸ generating icon"
swiftc -O scripts/make_icon.swift -o /tmp/make_icon
ICONSET_DIR="/tmp/claudophobia-icon.iconset"
rm -rf "$ICONSET_DIR"
/tmp/make_icon "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$RES_DIR/AppIcon.icns"

echo "▸ writing Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>MIT License</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "▸ ad-hoc codesigning"
codesign --force --deep --sign - "$APP_DIR"

echo "✓ Built ${APP_DIR}"
echo "  Launch with: open ${APP_DIR}"
