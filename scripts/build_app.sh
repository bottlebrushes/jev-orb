#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "Building JevOrb binary..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/JevOrb"
APP_DIR="$DIR/build/JevOrb.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/JevOrb"
chmod +x "$APP_DIR/Contents/MacOS/JevOrb"

cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>JevOrb</string>
    <key>CFBundleIdentifier</key>
    <string>ai.jev.orb</string>
    <key>CFBundleName</key>
    <string>JevOrb</string>
    <key>CFBundleDisplayName</key>
    <string>Jev Orb</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>JevOrb needs microphone access to listen to your voice commands for autonomous browser control.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>JevOrb needs automation access to control browser windows.</string>
</dict>
</plist>
EOF

echo "✓ Created $APP_DIR"
echo "You can launch it with: open \"$APP_DIR\""
