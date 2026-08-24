#!/bin/bash
# Build, Developer-ID-sign, notarise, and staple a fanmon .dmg (and the .app
# inside it) for direct (non-App-Store) distribution.
#
# Config is read from packaging/release.env (gitignored) or the environment:
#   SIGN_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)"
#   ASC_KEY        path to the App Store Connect API .p8 key
#   ASC_KEY_ID     key id
#   ASC_ISSUER     issuer id
#   BUNDLE_ID      (optional) real reverse-DNS id for the signed build
#
# Usage: packaging/release.sh <version>      e.g. packaging/release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

# `set -a` so sourced vars (esp. BUNDLE_ID) are exported to the child build.sh.
[ -f packaging/release.env ] && { set -a; source packaging/release.env; set +a; }
VERSION="${1:?usage: packaging/release.sh <version>   e.g. 1.0.0}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY (see packaging/release.env.example)}"
: "${ASC_KEY:?set ASC_KEY}"; : "${ASC_KEY_ID:?set ASC_KEY_ID}"; : "${ASC_ISSUER:?set ASC_ISSUER}"

APP="build/Fanmon.app"
ZIP="build/Fanmon.zip"
DMG="build/Fanmon-${VERSION}.dmg"

notarize() { xcrun notarytool submit "$1" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait; }

echo "▸ Building…"
./build.sh >/dev/null

echo "▸ Signing (Developer ID + Hardened Runtime)…"
codesign --force --options runtime --timestamp \
  --entitlements packaging/entitlements.plist \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Notarising the app, then stapling it…"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "▸ Building DMG from the stapled app…"
rm -f "$DMG"
hdiutil create -volname "Fanmon" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "▸ Notarising the DMG, then stapling it…"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "✅ Notarised, stapled DMG ready:"
shasum -a 256 "$DMG"