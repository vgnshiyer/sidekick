#!/bin/sh
# Build Sidekick in release mode and assemble a signed build/Sidekick.app.
#
#   scripts/bundle.sh [signing identity]
#
# Signs with the Developer ID identity by default ($SIDEKICK_SIGN_IDENTITY overrides it), or
# ad-hoc ("-") when that identity isn't in the keychain. Pass "-" to force an ad-hoc signature.
# $SIDEKICK_VERSION, when set, becomes the app's version.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEFAULT_IDENTITY=${SIDEKICK_SIGN_IDENTITY:-"Developer ID Application: Vignesh Iyer (2BFGSW8AFN)"}
IDENTITY=${1:-$DEFAULT_IDENTITY}
APP="$ROOT/build/Sidekick.app"

cd "$ROOT"
swift build -c release
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Sidekick" "$APP/Contents/MacOS/Sidekick"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${SIDEKICK_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SIDEKICK_VERSION" \
        -c "Set :CFBundleVersion $SIDEKICK_VERSION" "$APP/Contents/Info.plist"
fi

# SwiftPM resource bundles, minus the test targets' (Bundle.module looks in Contents/Resources first).
for bundle in "$BIN"/*.bundle; do
    case "$bundle" in
        *Tests.bundle) ;;
        *) cp -R "$bundle" "$APP/Contents/Resources/" ;;
    esac
done
[ -d "$APP/Contents/Resources/Sidekick_Sidekick.bundle" ] || { echo "error: Sidekick_Sidekick.bundle missing in $BIN" >&2; exit 1; }

# The bridge installers, laid out as in the repo, so people who only have the app can turn on sending:
#   /Applications/Sidekick.app/Contents/Resources/Bridge/scripts/install-claude-bridge.sh
BRIDGE="$APP/Contents/Resources/Bridge"
mkdir -p "$BRIDGE/scripts"
cp "$ROOT/scripts/install-claude-bridge.sh" "$ROOT/scripts/install-codex-hooks.sh" "$BRIDGE/scripts/"
rsync -a --exclude tests --exclude types --exclude tsconfig.json "$ROOT/bridge" "$BRIDGE/"

if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    echo "warning: signing identity not found, signing ad-hoc: $IDENTITY" >&2
    IDENTITY=-
fi

# Notarization needs a secure timestamp; an ad-hoc signature can't have one.
TIMESTAMP=--timestamp
[ "$IDENTITY" = "-" ] && TIMESTAMP=--timestamp=none
# Apple's timestamp server occasionally doesn't answer; try a few times before giving up.
for attempt in 1 2 3; do
    codesign --force --options runtime $TIMESTAMP \
        --entitlements "$ROOT/scripts/Sidekick.entitlements" \
        --sign "$IDENTITY" "$APP" && break
    [ "$attempt" = 3 ] && exit 1
    echo "codesign failed, retrying in 5 s" >&2
    sleep 5
done
codesign --verify --strict --verbose=2 "$APP"
echo "built $APP (signed: $IDENTITY)"
