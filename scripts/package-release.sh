#!/bin/sh
# Packages an already built and signed PressShot.app for the installer in ../install.sh.
#
#   scripts/package-release.sh /path/to/PressShot.app /path/to/output-folder
#
# Writes two files into the output folder (keep it outside this repository):
#   PressShot-<version>-<build>.zip   the app, archived with ditto so the signature survives
#   latest.json                       the manifest install.sh reads
#
# It does not build, sign, upload, or publish anything. Sign first; this script refuses an app whose signature does not verify
# or whose signer is not one install.sh accepts.
set -eu

BUNDLE_ID="com.derekhanson.pressshot"
PLIST=/usr/libexec/PlistBuddy
die() { printf 'package-release: %s\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: scripts/package-release.sh /path/to/PressShot.app /path/to/output-folder"
APP="${1%/}"; OUT="${2%/}"
[ -d "$APP" ] && [ "$(basename "$APP")" = "PressShot.app" ] || die "$APP is not a PressShot.app bundle."
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
case "$OUT/" in "$REPO_ROOT"/*) die "keep release files outside the repository ($OUT is inside it)." ;; esac

/usr/bin/codesign --verify --deep --strict "$APP" 2>/dev/null || die "the app's code signature does not verify. Sign it first."
[ "$("$PLIST" -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] || die "unexpected bundle identifier."

# The signer must be one the installer trusts, or every install would fail after download.
SIGNERS="$(sed -n 's/^[[:space:]]*TRUSTED_SIGNERS="\(.*\)"$/\1/p' "$REPO_ROOT/install.sh")"
[ -n "$SIGNERS" ] || die "couldn't read TRUSTED_SIGNERS from install.sh."
OK=0
for leaf in $SIGNERS; do
    if /usr/bin/codesign --verify -R="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$leaf\"" "$APP" 2>/dev/null; then OK=1; fi
done
[ "$OK" = 1 ] || die "this app is signed by a certificate install.sh doesn't list in TRUSTED_SIGNERS."

VERSION="$("$PLIST" -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
MIN_OS="$("$PLIST" -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
BUILD="$(/usr/bin/codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || die "couldn't read the app's version or build hash."
ARCHS="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/PressShot")"

ZIP_NAME="PressShot-$VERSION-$(printf '%s' "$BUILD" | cut -c1-12).zip"
rm -f "$OUT/$ZIP_NAME"
/usr/bin/ditto -c -k --keepParent "$APP" "$OUT/$ZIP_NAME"
SHA="$(/usr/bin/shasum -a 256 "$OUT/$ZIP_NAME" | cut -d' ' -f1)"
SIZE="$(/usr/bin/stat -f %z "$OUT/$ZIP_NAME")"

cat > "$OUT/latest.json" <<EOF
{
  "bundleID": "$BUNDLE_ID",
  "version": "$VERSION",
  "build": "$BUILD",
  "minimumSystemVersion": "$MIN_OS",
  "architectures": "$ARCHS",
  "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "zip": { "name": "$ZIP_NAME", "sha256": "$SHA", "size": $SIZE }
}
EOF
[ "$(/usr/bin/plutil -extract zip.sha256 raw -o - -- "$OUT/latest.json" 2>/dev/null)" = "$SHA" ] || die "wrote an invalid latest.json."

printf 'Packaged PressShot %s (build %s)\n  %s\n  %s\n' "$VERSION" "$BUILD" "$OUT/$ZIP_NAME" "$OUT/latest.json"
