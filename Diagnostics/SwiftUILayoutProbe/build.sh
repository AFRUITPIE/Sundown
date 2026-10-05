#!/bin/zsh
set -eu
probe_root=${0:A:h}
probe_destination=${1:-/private/tmp/SundownLayoutProbe.app}
mkdir -p "$probe_destination/Contents/MacOS"
cp "$probe_root/Info.plist" "$probe_destination/Contents/Info.plist"
xcrun swiftc -O -g -parse-as-library "$probe_root/LayoutProbe.swift" -o "$probe_destination/Contents/MacOS/LayoutProbe"
codesign --force --sign - "$probe_destination"
