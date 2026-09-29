#!/bin/sh
# Builds Tether for distribution and publishes it as a GitHub release, for the Homebrew cask:
# a Release archive signed with Developer ID, notarized and stapled, zipped, and uploaded as
# v<MARKETING_VERSION>. The tap (AFRUITPIE/homebrew-tap) picks the release up by itself.
#
# Merging a version bump runs this in CI (.github/workflows/release.yml). To run it here instead,
# once per Mac: a Developer ID Application certificate (Xcode ▸ Settings ▸ Accounts), and
#     xcrun notarytool store-credentials tether --apple-id <apple id> --team-id K4M2TD6G2A
# CI notarizes with an App Store Connect API key instead (NOTARY_KEY_PATH, NOTARY_KEY_ID,
# NOTARY_ISSUER).
set -eu
cd "$(dirname "$0")/.."

# The protocol package at its pin, not a sibling tether-server checkout.
export TETHER_USE_RELEASE=1
team=K4M2TD6G2A
out=build/release
version=$(xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
zip="$out/Tether-$version.zip"
echo "Tether $version"

rm -rf "$out"
mkdir -p "$out"
# Signed with the Developer ID certificate directly, so neither an Xcode account nor a
# development certificate is needed.
xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$out/Tether.xcarchive" archive -quiet \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$team"

cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>$team</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$out/Tether.xcarchive" -exportPath "$out" \
    -exportOptionsPlist "$out/ExportOptions.plist" -quiet

echo "Notarizing"
ditto -c -k --keepParent "$out/Tether.app" "$zip"
if [ -n "${NOTARY_KEY_ID:-}" ]; then
    set -- --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
else
    set -- --keychain-profile tether
fi
xcrun notarytool submit "$zip" "$@" --wait | tee "$out/notary.txt"
grep -q "status: Accepted" "$out/notary.txt"
xcrun stapler staple "$out/Tether.app"
spctl --assess --type execute --verbose "$out/Tether.app"

# Zipped again, with the ticket stapled in.
rm "$zip"
ditto -c -k --keepParent "$out/Tether.app" "$zip"
gh release create "v$version" "$zip" --target "$(git rev-parse HEAD)" --title "Tether $version" \
    --notes "Install with Homebrew: \`brew install --cask afruitpie/tap/tether\`"
