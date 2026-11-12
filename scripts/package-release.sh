#!/bin/sh
# Packages an already built and signed PressShot.app for the installer in ../install.sh.
#
#   scripts/package-release.sh /path/to/PressShot.app /path/to/output-folder
#
# Writes three files into the output folder (keep it outside this repository):
#   PressShot-<version>-<build>.zip   the app, archived with ditto so the signature survives
#   latest.json                       the manifest install.sh reads
#   appcast.xml                       the in-app update feed (Sparkle), signed with the
#                                     "pressshot" update key in the login Keychain
#
# Optional environment:
#   SPARKLE_BIN       folder holding Sparkle's sign_update and generate_keys
#                     (default: found in Xcode's DerivedData)
#   RELEASE_NOTES     an HTML file shown in the update window
#   FEED_BASE         where the zip will be served (default: https://get-pressshot.space.fast)
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
AUTH_SERVICE="$("$PLIST" -c 'Print :PressShotAuthServiceURL' "$APP/Contents/Info.plist" 2>/dev/null || true)"
case "$AUTH_SERVICE" in
    https://?*) ;;
    *) die "this build has no WordPress.com sign-in address (PressShotAuthServiceURL), so the WordPress.com button wouldn't work." ;;
esac
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

# In-app updates. The app only accepts an update signed with the key whose public half
# is in its Info.plist, so check the Keychain key matches before signing anything.
FEED_BASE="${FEED_BASE:-https://get-pressshot.space.fast}"
if [ -z "${SPARKLE_BIN:-}" ]; then
    SPARKLE_BIN="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)"
fi
[ -x "$SPARKLE_BIN/sign_update" ] && [ -x "$SPARKLE_BIN/generate_keys" ] || die "couldn't find Sparkle's sign_update. Set SPARKLE_BIN to Sparkle's bin folder."
APP_KEY="$("$PLIST" -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
FEED_URL="$("$PLIST" -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$FEED_URL" = "$FEED_BASE/appcast.xml" ] || die "this build's update feed ($FEED_URL) isn't $FEED_BASE/appcast.xml."
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" --account pressshot -p 2>/dev/null || true)"
[ -n "$APP_KEY" ] && [ "$APP_KEY" = "$KEYCHAIN_KEY" ] || die "the app's update key doesn't match the \"pressshot\" key in the Keychain."
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account pressshot "$OUT/$ZIP_NAME")" || die "couldn't sign the zip for updates."
case "$SIGNATURE" in *'sparkle:edSignature="'*) ;; *) die "sign_update returned an unexpected result." ;; esac
BUNDLE_VERSION="$("$PLIST" -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
NOTES=""
if [ -n "${RELEASE_NOTES:-}" ]; then
    [ -f "$RELEASE_NOTES" ] || die "RELEASE_NOTES ($RELEASE_NOTES) isn't a file."
    if grep -q ']]>' "$RELEASE_NOTES"; then die "RELEASE_NOTES can't contain ]]>."; fi
    NOTES="      <description><![CDATA[$(cat "$RELEASE_NOTES")]]></description>"
fi
cat > "$OUT/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PressShot</title>
    <link>$FEED_BASE/</link>
    <item>
      <title>PressShot $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUNDLE_VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
$NOTES
      <enclosure url="$FEED_BASE/$ZIP_NAME" $SIGNATURE type="application/octet-stream" />
    </item>
  </channel>
</rss>
APPCAST
/usr/bin/xmllint --noout "$OUT/appcast.xml" 2>/dev/null || die "wrote an invalid appcast.xml."

printf 'Packaged PressShot %s (build %s)\n  %s\n  %s\n  %s\n' "$VERSION" "$BUILD" "$OUT/$ZIP_NAME" "$OUT/latest.json" "$OUT/appcast.xml"
