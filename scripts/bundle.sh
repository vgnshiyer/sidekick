#!/bin/sh
# Build Sidekick in release mode and assemble a signed build/Sidekick.app.
#
#   scripts/bundle.sh [signing identity]
#
# Signs with the Developer ID identity by default, or ad-hoc ("-") when that
# identity isn't in the keychain. Pass "-" to force an ad-hoc signature.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEFAULT_IDENTITY="Developer ID Application: Vignesh Iyer (2BFGSW8AFN)"
IDENTITY=${1:-$DEFAULT_IDENTITY}
APP="$ROOT/build/Sidekick.app"

cd "$ROOT"
swift build -c release
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Sidekick" "$APP/Contents/MacOS/Sidekick"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM resource bundles, minus the test targets' (Bundle.module looks in Contents/Resources first).
for bundle in "$BIN"/*.bundle; do
    case "$bundle" in
        *Tests.bundle) ;;
        *) cp -R "$bundle" "$APP/Contents/Resources/" ;;
    esac
done
[ -d "$APP/Contents/Resources/Sidekick_Sidekick.bundle" ] || { echo "error: Sidekick_Sidekick.bundle missing in $BIN" >&2; exit 1; }

if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    echo "warning: signing identity not found, signing ad-hoc: $IDENTITY" >&2
    IDENTITY=-
fi

codesign --force --options runtime \
    --entitlements "$ROOT/scripts/Sidekick.entitlements" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "built $APP (signed: $IDENTITY)"
