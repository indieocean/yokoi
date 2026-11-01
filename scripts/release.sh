#!/bin/zsh
# Builds a Developer ID–signed, notarized and stapled Yokoi.dmg in build/release/.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain (Xcode › Settings › Accounts › Manage Certificates).
#   2. Store notarization credentials (an app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials yokoi-notary --apple-id you@example.com --team-id 3P2Q7V729Y
#
#   Or, instead of step 2 (used by GitHub Actions), an App Store Connect API key:
#        NOTARY_KEY_PATH=AuthKey.p8 NOTARY_KEY_ID=ABC123 NOTARY_ISSUER_ID=uuid scripts/release.sh
#   3. The Sparkle update-signing key, in the login keychain under the account "yokoi" (made once with
#      build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account yokoi). Its public half is
#      SUPublicEDKey in Config/Yokoi-Info.plist. GitHub Actions passes the exported key in SPARKLE_KEY_PATH instead.
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
# Packages are checked out here (outside $OUT, so they survive) to find Sparkle's sign_update afterwards.
PACKAGES="build/SourcePackages"
REPO_URL="https://github.com/indieocean/yokoi"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "error: no 'Developer ID Application' certificate found in the keychain." >&2
  echo "       Create one in Xcode › Settings › Accounts › Manage Certificates." >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "› Archiving"
xcodebuild -project Yokoi.xcodeproj -scheme Yokoi -configuration Release \
  -archivePath "$ARCHIVE" -destination "generic/platform=macOS" -clonedSourcePackagesDirPath "$PACKAGES" \
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
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist")
DMG="$OUT/Yokoi-$VERSION.dmg"

echo "› Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID|flags=.*runtime" \
  || { echo "error: not signed with Developer ID + hardened runtime" >&2; exit 1; }

echo "› Building $DMG"
# dmgbuild lays out the window (background, icon positions) and sets the volume icon without scripting
# Finder, so it also works on headless CI. Installed once into a venv under build/.
VENV="build/dmgbuild-venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "dmgbuild==1.6.7"
fi
cp "$APP/Contents/Resources/AppIcon.icns" "$OUT/VolumeIcon.icns"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py \
  -D app="$APP" -D icon="$OUT/VolumeIcon.icns" -D background=assets/dmg/background.tiff \
  "Yokoi $VERSION" "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
  echo "✓ Signed (not notarized): $DMG"
  exit 0
fi

echo "› Notarizing (this usually takes a few minutes)"
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

# Name only, so `shasum -c` works next to the downloaded DMG.
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256"

# Sparkle: sign the final (stapled) DMG and write the one-item appcast that is attached to the release.
# Installed copies read it from releases/latest/download/appcast.xml and compare sparkle:version with
# their CFBundleVersion, so CURRENT_PROJECT_VERSION must go up with every release.
echo "› Signing the update for Sparkle"
SIGN_UPDATE="$PACKAGES/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -n "${SPARKLE_KEY_PATH:-}" ]]; then
  SPARKLE_SIG=$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_PATH" "$DMG")
else
  SPARKLE_SIG=$("$SIGN_UPDATE" --account yokoi "$DMG")
fi
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Yokoi</title>
    <link>$REPO_URL</link>
    <item>
      <title>Yokoi $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO_URL/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/$(basename "$DMG")" type="application/octet-stream" $SPARKLE_SIG />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT/appcast.xml"

echo "✓ Ready to upload: $DMG"
echo "  gh release create v$VERSION '$DMG' '$DMG.sha256' '$OUT/appcast.xml' --title 'Yokoi $VERSION' --generate-notes"
