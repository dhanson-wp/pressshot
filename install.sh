#!/bin/sh
# PressShot installer. Downloads the latest build, checks it, and puts it in Applications.
# Run it again any time to upgrade. It never asks a question, so a person or an agent can run it.
#
#   curl -fsSL https://get-pressshot.space.fast/install.sh | sh
#   curl -fsSL https://get-pressshot.space.fast/install.sh | sh -s -- --json        (agents: one JSON line on stdout)
#
# Options (each also has an environment variable, for use with a pipe):
#   --check          report installed and latest builds; change nothing     PRESSSHOT_CHECK=1
#   --json           print one JSON result line on stdout; prose to stderr  PRESSSHOT_JSON=1
#   --no-open        don't launch PressShot afterwards                      PRESSSHOT_NO_OPEN=1
#   --no-quit        fail instead of quitting a running PressShot           PRESSSHOT_NO_QUIT=1
#   --reinstall      install even when this build is already there          PRESSSHOT_REINSTALL=1
#   --dir <folder>   where PressShot.app goes                               PRESSSHOT_INSTALL_DIR
#   --feed <url>     folder URL holding latest.json and the zip             PRESSSHOT_FEED
#
# Exit codes: 0 done (or nothing to do), 1 unexpected failure, 2 bad option or no feed,
# 3 this Mac can't run PressShot, 4 download or verification failed, 5 PressShot is running
# and --no-quit was given.
#
# What it checks: the archive's size and SHA-256 against the manifest, that the archive holds
# exactly one PressShot.app, and that the app is validly signed by a certificate listed in
# TRUSTED_SIGNERS below. The manifest itself is trusted over TLS.
#
# PressShot isn't notarized by Apple yet. Fetching it with curl, as this script does, avoids the
# "can't be opened" warning a browser download would trigger.
#
# Everything lives in main(), so a download cut off halfway runs nothing.
main() {
    set -eu
    BUNDLE_ID="com.derekhanson.pressshot"
    # SHA-1 of each signing certificate allowed to sign a release, space separated.
    # Add the Developer ID certificate's hash here when PressShot moves to one.
    TRUSTED_SIGNERS="7963cad4980518aad8aefa7797d93c124900ee93"
    # Folder URL that serves latest.json and the zip.
    DEFAULT_FEED="https://get-pressshot.space.fast"
    PLIST=/usr/libexec/PlistBuddy

    CHECK="${PRESSSHOT_CHECK:-0}"; JSON="${PRESSSHOT_JSON:-0}"; NO_OPEN="${PRESSSHOT_NO_OPEN:-0}"
    NO_QUIT="${PRESSSHOT_NO_QUIT:-0}"; REINSTALL="${PRESSSHOT_REINSTALL:-0}"
    INSTALL_DIR="${PRESSSHOT_INSTALL_DIR:-}"; FEED="${PRESSSHOT_FEED:-$DEFAULT_FEED}"
    STATUS="failed"; VERSION=""; BUILD=""; DEST=""; PREVIOUS=""

    say() { if [ "$JSON" = 1 ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }
    esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    result() {
        [ "$JSON" = 1 ] || return 0
        printf '{"status":"%s","version":"%s","build":"%s","previous_build":"%s","path":"%s","message":"%s","needs_human":%s}\n' \
            "$STATUS" "$(esc "$VERSION")" "$(esc "$BUILD")" "$(esc "$PREVIOUS")" "$(esc "$DEST")" "$(esc "$1")" "$2"
    }
    die() { code="$1"; shift; printf 'PressShot installer: %s\n' "$*" >&2; STATUS="failed"; result "$*" '[]'; exit "$code"; }
    plist() { "$PLIST" -c "Print :$2" "$1" 2>/dev/null; }
    json() { /usr/bin/plutil -extract "$2" raw -o - -- "$1" 2>/dev/null; }
    build_of() { /usr/bin/codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1; }
    trusted() {
        for leaf in $TRUSTED_SIGNERS; do
            /usr/bin/codesign --verify --deep --strict -R="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$leaf\"" "$1" 2>/dev/null && return 0
        done
        return 1
    }
    HUMAN_STEPS='["Allow Screen Recording when macOS asks (System Settings > Privacy & Security > Screen & System Audio Recording), then quit and reopen PressShot.","Open PressShot Settings > Upload destinations, click Connect a site, enter your site address, click Yes, I approve of this connection on the WordPress page, and Save.","On the first upload after each update, enter the Mac password in the Keychain prompt and choose Always Allow."]'

    while [ $# -gt 0 ]; do
        case "$1" in
            --check) CHECK=1 ;;
            --json) JSON=1 ;;
            --no-open) NO_OPEN=1 ;;
            --no-quit) NO_QUIT=1 ;;
            --reinstall) REINSTALL=1 ;;
            --dir) [ $# -ge 2 ] || die 2 "--dir needs a folder."; INSTALL_DIR="$2"; shift ;;
            --feed) [ $# -ge 2 ] || die 2 "--feed needs a URL."; FEED="$2"; shift ;;
            *) die 2 "unknown option $1." ;;
        esac
        shift
    done

    [ "$(id -u)" -ne 0 ] || die 2 "don't run this with sudo or as root; install as the person who will use PressShot."
    [ "$(uname -s)" = "Darwin" ] || die 3 "PressShot is a Mac app."
    command -v curl >/dev/null || die 1 "curl is missing."
    [ -n "$FEED" ] || die 2 "no release location is configured yet. Pass --feed <url> or set PRESSSHOT_FEED."
    FEED="${FEED%/}"
    case "$FEED" in https://*|file:///*) ;; *) die 2 "the feed must be an https:// URL (or file:/// for local testing)." ;; esac
    MACOS="$(sw_vers -productVersion)"

    TMP="$(mktemp -d "${TMPDIR:-/tmp}/pressshot-install.XXXXXX")"
    trap 'rm -rf "$TMP"' EXIT INT TERM

    say "Checking the latest PressShot build..."
    curl -fsSL -o "$TMP/latest.json" "$FEED/latest.json" || die 4 "couldn't fetch the release info from $FEED/latest.json."
    [ "$(json "$TMP/latest.json" bundleID)" = "$BUNDLE_ID" ] || die 4 "the release info describes a different app or isn't in the expected format."
    VERSION="$(json "$TMP/latest.json" version)"
    BUILD="$(json "$TMP/latest.json" build)"
    MIN_OS="$(json "$TMP/latest.json" minimumSystemVersion)"
    ZIP_NAME="$(json "$TMP/latest.json" zip.name)"
    ZIP_SHA="$(json "$TMP/latest.json" zip.sha256)"
    ZIP_SIZE="$(json "$TMP/latest.json" zip.size)"
    [ -n "$VERSION" ] && [ -n "$BUILD" ] && [ -n "$ZIP_NAME" ] && [ -n "$ZIP_SHA" ] && [ -n "$ZIP_SIZE" ] || die 4 "the release info is incomplete."
    case "$ZIP_NAME" in */*|*' '*|'') die 4 "the release names an unexpected archive." ;; esac
    OLDEST="$(printf '%s\n%s\n' "${MIN_OS:-0}" "$MACOS" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
    [ -z "$MIN_OS" ] || [ "$OLDEST" = "$MIN_OS" ] || die 3 "PressShot $VERSION needs macOS $MIN_OS or newer; this Mac runs $MACOS."

    if [ -n "$INSTALL_DIR" ]; then DEST_DIR="$INSTALL_DIR"
    elif [ -d /Applications/PressShot.app ]; then DEST_DIR=/Applications
    elif [ -d "$HOME/Applications/PressShot.app" ]; then DEST_DIR="$HOME/Applications"
    elif [ -w /Applications ]; then DEST_DIR=/Applications
    else DEST_DIR="$HOME/Applications"
    fi
    DEST="${DEST_DIR%/}/PressShot.app"
    [ ! -d "$DEST" ] || PREVIOUS="$(build_of "$DEST")"

    if [ "$CHECK" = 1 ]; then
        if [ ! -d "$DEST" ]; then STATUS="not_installed"; MSG="PressShot isn't installed. Latest is $VERSION (build $BUILD)."
        elif [ "$PREVIOUS" = "$BUILD" ]; then STATUS="current"; MSG="PressShot $VERSION (build $BUILD) is installed and current."
        else STATUS="update_available"; MSG="An update is available: $VERSION (build $BUILD)."
        fi
        say "$MSG"; result "$MSG" '[]'; exit 0
    fi

    if [ -d "$DEST" ] && [ "$PREVIOUS" = "$BUILD" ] && [ "$REINSTALL" != 1 ]; then
        STATUS="current"; MSG="PressShot $VERSION is already installed at $DEST."
        say "$MSG"
        [ "$NO_OPEN" = 1 ] || /usr/bin/open "$DEST" || true
        result "$MSG" '[]'; exit 0
    fi

    mkdir -p "$DEST_DIR" 2>/dev/null || die 1 "can't create $DEST_DIR."
    [ -w "$DEST_DIR" ] || die 1 "can't write to $DEST_DIR. Pass --dir with a folder you own."

    say "Downloading $ZIP_NAME..."
    curl -fsSL -o "$TMP/$ZIP_NAME" "$FEED/$ZIP_NAME" || die 4 "the download failed ($FEED/$ZIP_NAME)."
    ACTUAL_SIZE="$(/usr/bin/stat -f %z "$TMP/$ZIP_NAME")"
    [ "$ACTUAL_SIZE" = "$ZIP_SIZE" ] || die 4 "the download is $ACTUAL_SIZE bytes, not the $ZIP_SIZE the release promised. Nothing was installed."
    ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$TMP/$ZIP_NAME" | cut -d' ' -f1)"
    [ "$ACTUAL_SHA" = "$ZIP_SHA" ] || die 4 "the download's checksum doesn't match the release. Nothing was installed."

    # ditto keeps the code signature intact; unzip can break it.
    mkdir "$TMP/unpacked"
    /usr/bin/ditto -x -k "$TMP/$ZIP_NAME" "$TMP/unpacked" || die 4 "couldn't unpack the download."
    NEW="$TMP/unpacked/PressShot.app"
    [ -d "$NEW" ] || die 4 "the archive doesn't contain PressShot.app."
    [ "$(ls -A "$TMP/unpacked" | wc -l | tr -d ' ')" = 1 ] || die 4 "the archive contains more than PressShot.app."
    trusted "$NEW" || die 4 "the downloaded app isn't validly signed by a trusted PressShot certificate. Nothing was installed."
    [ "$(plist "$NEW/Contents/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] || die 4 "the downloaded app is not PressShot."
    [ "$(build_of "$NEW")" = "$BUILD" ] || die 4 "the downloaded app is not the build the release describes. Nothing was installed."
    # curl doesn't set the quarantine flag, but clear it in case this archive came another way.
    /usr/bin/xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true

    if /usr/bin/pgrep -xq PressShot; then
        [ "$NO_QUIT" != 1 ] || die 5 "PressShot is running. Quit it (finish any recording first) and run the installer again."
        say "Quitting the running PressShot..."
        /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        i=0
        while /usr/bin/pgrep -xq PressShot && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
        ! /usr/bin/pgrep -xq PressShot || die 5 "PressShot is still running. Quit it (finish any recording first) and run the installer again."
    fi

    OLD=""
    if [ -d "$DEST" ]; then
        OLD="$DEST_DIR/.PressShot-old-$$.app"
        mv "$DEST" "$OLD" || die 1 "couldn't move the existing copy aside."
    fi
    if /usr/bin/ditto "$NEW" "$DEST" && trusted "$DEST"; then
        [ -z "$OLD" ] || rm -rf "$OLD"
    else
        rm -rf "$DEST"
        [ -z "$OLD" ] || mv "$OLD" "$DEST"
        die 1 "installing into $DEST_DIR failed; the previous copy was put back."
    fi
    touch "$DEST"
    [ "$NO_OPEN" = 1 ] || /usr/bin/open "$DEST" || true

    if [ -n "$PREVIOUS" ]; then STATUS="upgraded"; else STATUS="installed"; fi
    MSG="Installed PressShot $VERSION to $DEST."
    say ""
    say "$MSG"
    say "Next, three things only you can do:"
    say "  1. Allow Screen Recording when macOS asks, then quit and reopen PressShot."
    say "  2. In PressShot Settings > Upload destinations, click Connect a site, enter your site address, click Yes, I approve of this connection on the WordPress page, and Save."
    say "  3. On the first upload after each update, enter your Mac password in the Keychain prompt and choose Always Allow."
    result "$MSG" "$HUMAN_STEPS"
}

main "$@"
