#!/bin/bash
# Puts the standalone tether server binaries into the app bundle.
#
# A sibling checkout wins when it has binaries for the pinned version, so changing the server and
# running `mise run compile` next door is picked up with no extra step. Otherwise the pinned
# release is downloaded once and cached, which is what lets this repo be cloned on its own.
set -euo pipefail

VERSION="$(tr -d '[:space:]' < "$SRCROOT/.tether-server-version")"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/servers"
CACHE="${DERIVED_FILE_DIR:-$SRCROOT/.build}/tether-server/$VERSION"
LOCAL="$SRCROOT/../tether-server/dist"

mkdir -p "$DEST"

if ls "$LOCAL"/tether-"$VERSION"-* >/dev/null 2>&1; then
    echo "note: using sibling checkout $LOCAL"
    cp -f "$LOCAL"/tether-"$VERSION"-* "$DEST"/
    exit 0
fi

if ! ls "$CACHE"/tether-"$VERSION"-* >/dev/null 2>&1; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: need the server binaries for $VERSION. Install the GitHub CLI (brew install gh; gh auth login), or clone tether-server beside this repo and run 'mise run compile'."
        exit 1
    fi
    echo "note: downloading tether-server $VERSION"
    mkdir -p "$CACHE"
    if ! gh release download "v$VERSION" --repo AFRUITPIE/tether-server \
         --pattern "tether-$VERSION-*" --dir "$CACHE" --clobber; then
        rm -rf "$CACHE"
        echo "error: could not download tether-server v$VERSION. Check 'gh auth status' — the repo is private."
        exit 1
    fi
    chmod +x "$CACHE"/tether-"$VERSION"-*
fi

cp -f "$CACHE"/tether-"$VERSION"-* "$DEST"/
