#!/bin/sh
# Builds Sundown for distribution and publishes it as a GitHub release, for the Homebrew cask:
# a Release archive signed with Developer ID, notarized and stapled, zipped, and uploaded as
# v<MARKETING_VERSION>. Prints the zip's SHA-256 for the cask.
#
# With --beta, a beta instead, of a pull request (by number), a branch, or this checkout: a
# pre-release v<MARKETING_VERSION>-beta.<UTC time>, which the tap's sundown@beta cask is moved to
# (`brew install --cask afruitpie/tap/sundown@beta`, in place of Sundown). Everything happens on this
# Mac; the tap's daily update follows only full releases.
#
# Merging a version bump runs this in CI (.github/workflows/release.yml). To run it here instead,
# once per Mac: a Developer ID Application certificate (Xcode ▸ Settings ▸ Accounts), and
#     xcrun notarytool store-credentials sundown --apple-id <apple id> --team-id K4M2TD6G2A
# CI notarizes with an App Store Connect API key instead (NOTARY_KEY_PATH, NOTARY_KEY_ID,
# NOTARY_ISSUER).
#
# Run from a checkout of what's being released, pushed:
#     Scripts/release.sh
#     Scripts/release.sh --beta [<pull request number> | <branch>]
set -eu
cd "$(dirname "$0")/.."

beta=
if [ "${1:-}" = --beta ]; then
    beta=1
    ref=${2:-}
    if [ -n "$ref" ]; then
        # A pull request's branch, or the branch named; built in a worktree of its own.
        case $ref in
            *[!0-9]*) branch=$ref ;;
            *) branch=$(gh pr view "$ref" --json headRefName -q .headRefName) ;;
        esac
        git fetch -q origin "$branch"
        repo=$(pwd)
        work=$(mktemp -d)
        git worktree add -q --detach "$work/sundown" "origin/$branch"
        trap 'git -C "$repo" worktree remove --force "$work/sundown"; rm -rf "$work"' EXIT
        cd "$work/sundown"
        label=$branch
    else
        label=$(git branch --show-current)
    fi
fi
# A release says which commit it is, so that commit has to be on GitHub.
[ -n "$(git branch -r --contains HEAD)" ] || { echo "Push $(git rev-parse --short HEAD) first."; exit 1; }

# The protocol package at its pin, not a sibling tether-server checkout.
export SUNDOWN_USE_RELEASE=1
team=K4M2TD6G2A
out=build/release
version=$(xcodebuild -project Sundown.xcodeproj -scheme Sundown -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
[ -z "$beta" ] || version="$version-beta.$(date -u +%Y%m%d%H%M)"
zip="$out/Sundown-$version.zip"
echo "Sundown $version"

rm -rf "$out"
mkdir -p "$out"
# Signed with the Developer ID certificate directly, so neither an Xcode account nor a
# development certificate is needed.
xcodebuild -project Sundown.xcodeproj -scheme Sundown -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$out/Sundown.xcarchive" archive -quiet \
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
xcodebuild -exportArchive -archivePath "$out/Sundown.xcarchive" -exportPath "$out" \
    -exportOptionsPlist "$out/ExportOptions.plist" -quiet

echo "Notarizing"
ditto -c -k --keepParent "$out/Sundown.app" "$zip"
if [ -n "${NOTARY_KEY_ID:-}" ]; then
    set -- --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
else
    set -- --keychain-profile sundown
fi
xcrun notarytool submit "$zip" "$@" --wait | tee "$out/notary.txt"
grep -q "status: Accepted" "$out/notary.txt"
xcrun stapler staple "$out/Sundown.app"
spctl --assess --type execute --verbose "$out/Sundown.app"

# Zipped again, with the ticket stapled in.
rm "$zip"
ditto -c -k --keepParent "$out/Sundown.app" "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)

if [ -z "$beta" ]; then
    gh release create "v$version" "$zip" --target "$(git rev-parse HEAD)" --title "Sundown $version" \
        --notes "Install with Homebrew: \`brew install --cask afruitpie/tap/sundown\`"
    echo "sha256 $sha"
    exit
fi

gh release create "v$version" "$zip" --prerelease --target "$(git rev-parse HEAD)" --title "Sundown $version" \
    --notes "A beta of \`$label\` at $(git rev-parse --short HEAD). Install with Homebrew, in place of Sundown: \`brew uninstall --cask sundown; brew install --cask afruitpie/tap/sundown@beta\`"

# The tap's sundown@beta cask, written for this build: the same app as Sundown, so one or the other.
tap=$(mktemp -d)
gh repo clone AFRUITPIE/homebrew-tap "$tap" -- --quiet
cat > "$tap/Casks/sundown@beta.rb" <<EOF
cask "sundown@beta" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/AFRUITPIE/tether-app/releases/download/v#{version}/Sundown-#{version}.zip"
  name "Sundown"
  desc "Native client for Claude Code, locally or over SSH (beta builds)"
  homepage "https://github.com/AFRUITPIE/tether-app"

  conflicts_with cask: "sundown"
  depends_on macos: :golden_gate

  app "Sundown.app"

  zap trash: [
    "~/Library/Application Support/com.haydenhong.Sundown",
    "~/Library/Caches/com.haydenhong.Sundown",
    "~/Library/Preferences/com.haydenhong.Sundown.plist",
    "~/Library/Saved Application State/com.haydenhong.Sundown.savedState",
  ]
end
EOF
git -C "$tap" add Casks/sundown@beta.rb
git -C "$tap" commit -qm "sundown@beta $version"
git -C "$tap" push -q
rm -rf "$tap"
echo "sundown@beta is $version"
