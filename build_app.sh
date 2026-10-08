#!/bin/bash
# Builds IconDecompositor.app; installs it to /Applications unless --no-install is given.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/IconDecompositor.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -O "$DIR"/Sources/*.swift -o "$APP/Contents/MacOS/IconDecompositor"
cp "$DIR/icon/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>IconDecompositor</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-com.doraorak.IconDecompositor}</string>
    <key>CFBundleName</key><string>Icon Decompositor</string>
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
    rm -rf /Applications/IconDecompositor.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/IconDecompositor.app"
fi
