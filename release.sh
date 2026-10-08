#!/bin/bash
# Builds, signs (Developer ID, hardened runtime), notarizes and staples IconDecomposer.dmg into ./build.
# Needs SIGN_IDENTITY (e.g. "Developer ID Application: Name (TEAMID)") and a notarytool keychain
# profile (NOTARY_PROFILE, default "notarytool").
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
PROFILE="${NOTARY_PROFILE:-notarytool}"
APP="$DIR/build/IconDecomposer.app"
DMG="$DIR/build/IconDecomposer.dmg"

"$DIR/build_app.sh" --no-install
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"

ditto -c -k --keepParent "$APP" "$DIR/build/app.zip"
xcrun notarytool submit "$DIR/build/app.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Icon Decomposer" -srcfolder "$STAGE" -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
echo "Release build: $DMG"
