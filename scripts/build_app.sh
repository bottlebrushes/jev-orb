#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "Building JevOrb binary..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/JevOrb"
APP_DIR="$DIR/build/JevOrb.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/JevOrb.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/JevOrb"
chmod +x "$APP_DIR/Contents/MacOS/JevOrb"
cp "$DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
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
    <string>JevOrb uses your microphone to hear voice commands for navigating apps through macOS Accessibility controls.</string>
</dict>
</plist>
EOF

# TCC continuity depends on keeping the bundle identifier, designated
# requirement, and canonical installed path stable across rebuilds.
echo 'designated => identifier "ai.jev.orb"' | csreq -r- -b /tmp/req.bin
codesign --force --deep -s - -r /tmp/req.bin "$APP_DIR"

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
ditto "$APP_DIR" "$INSTALLED_APP"

echo "✓ Created and signed $APP_DIR"
echo "✓ Installed canonical app at $INSTALLED_APP"
echo "You can launch with: open \"$INSTALLED_APP\""
