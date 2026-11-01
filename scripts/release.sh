#!/bin/zsh
# Builds a Developer ID–signed, notarized and stapled Yokoi.dmg in build/release/.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain (Xcode › Settings › Accounts › Manage Certificates).
#   2. Store notarization credentials (an app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials yokoi-notary --apple-id you@example.com --team-id 3P2Q7V729Y
#
# Usage:
#   scripts/release.sh                 # uses MARKETING_VERSION from the project
#   NOTARY_PROFILE=other scripts/release.sh
#   SKIP_NOTARIZE=1 scripts/release.sh # signed build only, for a dry run
set -euo pipefail

cd "$(dirname "$0")/.."
TEAM_ID="${TEAM_ID:-3P2Q7V729Y}"
NOTARY_PROFILE="${NOTARY_PROFILE:-yokoi-notary}"
OUT="build/release"
ARCHIVE="$OUT/Yokoi.xcarchive"
EXPORT="$OUT/export"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "error: no 'Developer ID Application' certificate found in the keychain." >&2
  echo "       Create one in Xcode › Settings › Accounts › Manage Certificates." >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "› Archiving"
xcodebuild -project Yokoi.xcodeproj -scheme Yokoi -configuration Release \
  -archivePath "$ARCHIVE" -destination "generic/platform=macOS" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  -quiet archive

echo "› Exporting"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OUT/ExportOptions.plist"

APP="$EXPORT/Yokoi.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUT/Yokoi-$VERSION.dmg"

echo "› Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID|flags=.*runtime" \
  || { echo "error: not signed with Developer ID + hardened runtime" >&2; exit 1; }

echo "› Building $DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Yokoi $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
  echo "✓ Signed (not notarized): $DMG"
  exit 0
fi

echo "› Notarizing (this usually takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ Ready to upload: $DMG"
echo "  gh release create v$VERSION '$DMG' '$DMG.sha256' --title 'Yokoi $VERSION' --generate-notes"
