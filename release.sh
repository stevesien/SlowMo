#!/bin/bash
# Builds a signed, notarized SlowMo-<version>.dmg ready to put on a website.
# Run:  bash ~/Developer/SlowMo/release.sh
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-SlowMo-notary}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

# 1. Find the Developer ID certificate in the keychain.
IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [[ -z "$IDENTITY" ]]; then
  echo "No 'Developer ID Application' certificate found in your keychain."
  echo "Create one in Xcode: Settings > Accounts > (your Apple ID) > Manage Certificates > + > Developer ID Application."
  exit 1
fi
TEAM_ID=$(sed -E 's/.*\(([A-Z0-9]+)\)$/\1/' <<<"$IDENTITY")
echo "Signing as: $IDENTITY"

# 2. Make sure notarization credentials are stored.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo
  echo "One-time setup needed: store your notarization credentials. Run this, then run release.sh again:"
  echo
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id YOUR_APPLE_ID_EMAIL --team-id $TEAM_ID"
  echo
  echo "It will ask for an app-specific password: create one at https://account.apple.com (Sign-In and Security > App-Specific Passwords)."
  exit 1
fi

# 3. Build a universal (Apple Silicon + Intel) app.
BUILD="release"
rm -rf "$BUILD"
APP="$BUILD/SlowMo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  echo "Compiling for ${arch}..."
  swiftc -O -target "${arch}-apple-macos13" -o "$BUILD/SlowMo-${arch}" main.swift
done
lipo -create -output "$APP/Contents/MacOS/SlowMo" "$BUILD/SlowMo-arm64" "$BUILD/SlowMo-x86_64"
cp Info.plist "$APP/Contents/Info.plist"
if [[ -f AppIcon.icns ]]; then cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

# 4. Sign with hardened runtime (required for notarization).
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 5. Package as a .dmg with an Applications shortcut.
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$BUILD/SlowMo-${VERSION}.dmg"
hdiutil create -volname "SlowMo" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# 6. Notarize with Apple and staple the ticket.
echo "Sending to Apple for notarization (usually 1-5 minutes)..."
OUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 || true)
echo "$OUT"
if ! grep -q "status: Accepted" <<<"$OUT"; then
  echo
  echo "Notarization did not succeed. To see why, run:"
  echo "  xcrun notarytool log <submission id above> --keychain-profile $PROFILE"
  exit 1
fi
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

echo
echo "Done: $(pwd)/$DMG"
open -R "$DMG"
