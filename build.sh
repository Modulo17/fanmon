#!/bin/bash
# Build fanmon into a menu-bar .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

# Reverse-DNS bundle identifier. This is a neutral placeholder — to rebrand,
# change it to your own domain (e.g. com.yourname.fanmon). It must match the
# LaunchAgent Label if you install one (see README → "Start automatically").
BUNDLE_ID="com.example.fanmon"

APP="build/Fanmon.app"
MACOS="$APP/Contents/MacOS"
rm -rf "$APP"
mkdir -p "$MACOS"

echo "Compiling…"
swiftc -O \
  -import-objc-header bridge/fanmon-bridge.h \
  -framework Cocoa -framework IOKit \
  Sources/main.swift \
  -o "$MACOS/fanmon"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Fanmon</string>
    <key>CFBundleDisplayName</key>     <string>Fanmon</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleExecutable</key>      <string>fanmon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key><string>fanmon</string>
</dict>
</plist>
PLIST

echo "Built $APP  ($BUNDLE_ID)"

# If installed as a login agent, restart the running instance so the new
# binary takes effect immediately (the symlink means the path is unchanged).
AGENT="gui/$(id -u)/${BUNDLE_ID}"
if launchctl print "$AGENT" >/dev/null 2>&1; then
    launchctl kickstart -k "$AGENT" && echo "Restarted login agent with new build."
fi
