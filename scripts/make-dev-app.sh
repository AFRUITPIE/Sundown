#!/bin/sh
# Wraps the SwiftPM TetherDevApp executable in a minimal .app bundle (with server binaries) for local testing.
set -e
cd "$(dirname "$0")/../TetherKit"
swift build --product TetherDevApp
APP=.build/TetherDev.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/servers"
cp .build/debug/TetherDevApp "$APP/Contents/MacOS/TetherDev"
cp ../../tether-server/dist/tether-*-darwin-* ../../tether-server/dist/tether-*-linux-* "$APP/Contents/Resources/servers/" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.haydenhong.tether.dev</string>
<key>CFBundleName</key><string>Tether Dev</string>
<key>CFBundleExecutable</key><string>TetherDev</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign -s - --force "$APP" >/dev/null 2>&1 || true
echo "$PWD/$APP"
