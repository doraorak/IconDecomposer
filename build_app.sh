#!/bin/bash
# Builds IconDecomposer.app; installs it to /Applications unless --no-install is given.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/IconDecomposer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -O "$DIR"/Sources/*.swift -o "$APP/Contents/MacOS/IconDecomposer"
cp "$DIR/icon/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>IconDecomposer</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-com.doraorak.IconDecomposer}</string>
    <key>CFBundleName</key><string>Icon Decomposer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ "${1:-}" == "--no-install" ]]; then
    echo "Built $APP"
else
    rm -rf /Applications/IconDecomposer.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/IconDecomposer.app"
fi
