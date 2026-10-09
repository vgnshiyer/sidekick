#!/bin/sh
# Build a signed, notarized build/Sidekick-<version>.dmg for a GitHub release.
#
#   scripts/release.sh <version>        e.g. scripts/release.sh 0.2.0
#
# Needs a Developer ID Application identity (see bundle.sh) and a notarytool keychain profile,
# made once with:
#   xcrun notarytool store-credentials sidekick-notary \
#       --apple-id <apple id> --team-id <team id> --password <app-specific password>
# $SIDEKICK_NOTARY_PROFILE picks a different profile name.
set -eu

VERSION=${1:?usage: scripts/release.sh <version>}
PROFILE=${SIDEKICK_NOTARY_PROFILE:-sidekick-notary}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Sidekick.app"
DMG="$ROOT/build/Sidekick-$VERSION.dmg"
WORK="$ROOT/build/release"

cd "$ROOT"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || {
    echo "error: no notarytool profile '$PROFILE' in the keychain; see the top of $0" >&2; exit 1; }

SIDEKICK_VERSION="$VERSION" scripts/bundle.sh
IDENTITY=$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')
[ -n "$IDENTITY" ] || { echo "error: $APP isn't signed with a Developer ID; notarization would fail" >&2; exit 1; }

# Submit a file for notarization and wait; fail with Apple's log when it isn't accepted.
notarize() {
    out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)
    status=$(printf '%s' "$out" | /usr/bin/python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))')
    if [ "$status" != "Accepted" ]; then
        id=$(printf '%s' "$out" | /usr/bin/python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))')
        echo "error: notarization of $1 returned '$status'" >&2
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
        exit 1
    fi
    echo "notarized $(basename "$1")"
}

rm -rf "$WORK" && mkdir -p "$WORK"

# 1. The app itself, so its ticket travels with it once it's dragged out of the DMG.
ditto -c -k --keepParent "$APP" "$WORK/Sidekick.zip"
notarize "$WORK/Sidekick.zip"
xcrun stapler staple "$APP"

# 2. A drag-to-Applications disk image around it.
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Sidekick.app"
ln -s /Applications "$WORK/dmg/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Sidekick $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO "$DMG"
for attempt in 1 2 3; do
    codesign --force --timestamp --sign "$IDENTITY" "$DMG" && break
    [ "$attempt" = 3 ] && exit 1
    sleep 5
done
notarize "$DMG"
xcrun stapler staple "$DMG"

# 3. What a downloader's Mac will check.
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
rm -rf "$WORK"
echo "built $DMG"
shasum -a 256 "$DMG"
