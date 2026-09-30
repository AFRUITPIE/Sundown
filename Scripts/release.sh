#!/bin/sh
# Builds Tether for distribution and publishes it as a GitHub release, for the Homebrew cask:
# a Release archive signed with Developer ID, notarized and stapled, zipped, and uploaded as
# v<MARKETING_VERSION>. Prints the zip's SHA-256 for the cask.
#
# With --beta, a beta instead, of a pull request (by number), a branch, or this checkout: a
# pre-release v<MARKETING_VERSION>-beta.<UTC time>, which the tap's tether@beta cask is moved to
# (`brew install --cask afruitpie/tap/tether@beta`, in place of Tether). Everything happens on this
# Mac; the tap's daily update follows only full releases.
#
# Once per Mac: a Developer ID Application certificate (Xcode ▸ Settings ▸ Accounts), and
#     xcrun notarytool store-credentials tether --apple-id <apple id> --team-id K4M2TD6G2A
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
        git worktree add -q --detach "$work/tether" "origin/$branch"
        trap 'git -C "$repo" worktree remove --force "$work/tether"; rm -rf "$work"' EXIT
        cd "$work/tether"
        label=$branch
    else
        label=$(git branch --show-current)
    fi
fi
# A release says which commit it is, so that commit has to be on GitHub.
[ -n "$(git branch -r --contains HEAD)" ] || { echo "Push $(git rev-parse --short HEAD) first."; exit 1; }

# The protocol package at its pin, not a sibling tether-server checkout.
export TETHER_USE_RELEASE=1
out=build/release
version=$(xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
[ -z "$beta" ] || version="$version-beta.$(date -u +%Y%m%d%H%M)"
zip="$out/Tether-$version.zip"
echo "Tether $version"

rm -rf "$out"
mkdir -p "$out"
xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$out/Tether.xcarchive" archive -quiet

cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>K4M2TD6G2A</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$out/Tether.xcarchive" -exportPath "$out" \
    -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates -quiet

echo "Notarizing"
ditto -c -k --keepParent "$out/Tether.app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile tether --wait | tee "$out/notary.txt"
grep -q "status: Accepted" "$out/notary.txt"
xcrun stapler staple "$out/Tether.app"
spctl --assess --type execute --verbose "$out/Tether.app"

# Zipped again, with the ticket stapled in.
rm "$zip"
ditto -c -k --keepParent "$out/Tether.app" "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)

if [ -z "$beta" ]; then
    gh release create "v$version" "$zip" --target "$(git rev-parse HEAD)" --title "Tether $version" \
        --notes "Install with Homebrew: \`brew install --cask afruitpie/tap/tether\`"
    echo "sha256 $sha"
    exit
fi

gh release create "v$version" "$zip" --prerelease --target "$(git rev-parse HEAD)" --title "Tether $version" \
    --notes "A beta of \`$label\` at $(git rev-parse --short HEAD). Install with Homebrew, in place of Tether: \`brew uninstall --cask tether; brew install --cask afruitpie/tap/tether@beta\`"

# The tap's tether@beta cask, written for this build: the same app as Tether, so one or the other.
tap=$(mktemp -d)
gh repo clone AFRUITPIE/homebrew-tap "$tap" -- --quiet
cat > "$tap/Casks/tether@beta.rb" <<EOF
cask "tether@beta" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/AFRUITPIE/tether-app/releases/download/v#{version}/Tether-#{version}.zip"
  name "Tether"
  desc "Native client for Claude Code, locally or over SSH (beta builds)"
  homepage "https://github.com/AFRUITPIE/tether-app"

  conflicts_with cask: "tether"
  depends_on macos: :golden_gate

  app "Tether.app"

  zap trash: [
    "~/Library/Application Support/com.haydenhong.Tether",
    "~/Library/Caches/com.haydenhong.Tether",
    "~/Library/Preferences/com.haydenhong.Tether.plist",
    "~/Library/Saved Application State/com.haydenhong.Tether.savedState",
  ]
end
EOF
git -C "$tap" add Casks/tether@beta.rb
git -C "$tap" commit -qm "tether@beta $version"
git -C "$tap" push -q
rm -rf "$tap"
echo "tether@beta is $version"
