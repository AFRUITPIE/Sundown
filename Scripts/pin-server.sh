#!/bin/sh
# Pins the Tether server this app runs to a released version: writes ServerPin.swift with the
# version npx runs and the SHA-256 of each of the release's binaries, which a copy is checked
# against. Run it after `mise run release` in tether-server, with that version:
#
#     Scripts/pin-server.sh 0.5.7
#
# and bump TetherKit/Package.swift's TetherProtocol pin to the same version.
set -eu

version=${1:?usage: Scripts/pin-server.sh <version>}
base=${TETHER_DOWNLOAD_BASE:-https://github.com/AFRUITPIE/tether-server/releases/download}
out="$(dirname "$0")/../TetherKit/Sources/TetherKit/ServerPin.swift"

sums=$(curl -fsSL "$base/v$version/SHA256SUMS")

{
    echo "// Written by Scripts/pin-server.sh $version from the release's SHA256SUMS; don't edit by hand."
    echo ""
    echo "extension ServerRelease {"
    echo "    /// The server version npx runs, and a copy puts on a host. Moves with the protocol package's"
    echo "    /// pin, which is the server this app was built against."
    echo "    public static let version = \"$version\""
    echo ""
    echo "    /// Each platform's binary's SHA-256, which a copy must match before it goes to a host."
    echo "    public static let checksums: [String: String] = ["
    echo "$sums" | while read -r digest file; do
        file=${file#\*}
        platform=${file#"tether-$version-"}
        [ "$platform" != "$file" ] || continue
        echo "        \"$platform\": \"$digest\","
    done
    echo "    ]"
    echo "}"
} > "$out"

echo "Pinned Tether $version in $out"
