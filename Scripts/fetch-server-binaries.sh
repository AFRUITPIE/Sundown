#!/bin/bash
# Puts the standalone tether server binaries into the app bundle.
#
# Local development: with a tether-server checkout beside this repo, that checkout is what the app
# runs. It is compiled here (`mise run compile -- --dev`) whenever its sources changed since the last
# dev build; the dev build carries a `-dev.<time>` version, so the running daemon replaces itself
# with it on the next connect. No release or pin bump is involved. TETHER_USE_RELEASE=1 opts out.
#
# Otherwise the release pinned in .tether-server-version is downloaded once and cached, which is
# what lets this repo be cloned and built on its own (and what CI does).
set -euo pipefail

# PR UI tests run entirely against an in-process fixture. No server binary is used there.
if [[ "${TETHER_SKIP_SERVER_BINARIES:-}" == "1" ]]; then
    echo "note: skipping server binaries for fixture UI tests"
    exit 0
fi

VERSION="$(tr -d '[:space:]' < "$SRCROOT/.tether-server-version")"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/servers"
CACHE="${DERIVED_FILE_DIR:-$SRCROOT/.build}/tether-server/$VERSION"
LOCAL="$SRCROOT/../tether-server/dist"

# Cleared first. Copying into a directory that already holds another version left several in the
# bundle, and the app then had to guess which to run — it picked the first the filesystem listed,
# which was the oldest, so a new app quietly ran an old server.
rm -rf "$DEST"
mkdir -p "$DEST"

SIBLING="$SRCROOT/../tether-server"
if [[ -f "$SIBLING/package.json" && "${TETHER_USE_RELEASE:-}" != "1" ]]; then
    newest_dev="$(ls -t "$LOCAL"/tether-*-dev.*-darwin-arm64 2>/dev/null | head -1 || true)"
    if [[ -z "$newest_dev" ]] || [[ -n "$(find "$SIBLING/src" "$SIBLING/package.json" "$SIBLING/bun.lock" -newer "$newest_dev" -print -quit 2>/dev/null)" ]]; then
        MISE="$(command -v mise || ls /opt/homebrew/bin/mise /opt/homebrew/opt/mise/bin/mise "$HOME/.local/bin/mise" 2>/dev/null | head -1 || true)"
        if [[ -z "$MISE" ]]; then
            echo "error: the sibling tether-server changed and needs rebuilding, but mise isn't installed. Install it (brew install mise), or set TETHER_USE_RELEASE=1 to use the pinned release."
            exit 1
        fi
        echo "note: compiling sibling tether-server (dev build)"
        (cd "$SIBLING" && "$MISE" run compile -- --dev)
    fi
    echo "note: using sibling tether-server dev build"
    cp -f "$LOCAL"/tether-*-dev.* "$DEST"/
    exit 0
fi

if ! ls "$CACHE"/tether-"$VERSION"-* >/dev/null 2>&1; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: need the server binaries for $VERSION. Install the GitHub CLI (brew install gh), or clone tether-server beside this repo and run 'mise run compile'."
        exit 1
    fi
    echo "note: downloading tether-server $VERSION"
    mkdir -p "$CACHE"
    if ! gh release download "v$VERSION" --repo AFRUITPIE/tether-server \
         --pattern "tether-$VERSION-*" --dir "$CACHE" --clobber; then
        rm -rf "$CACHE"
        echo "error: could not download tether-server v$VERSION. Check that the release and matching binaries exist."
        exit 1
    fi
    chmod +x "$CACHE"/tether-"$VERSION"-*
fi

cp -f "$CACHE"/tether-"$VERSION"-* "$DEST"/
