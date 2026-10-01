#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="${1:-$ROOT/build/Squirrel-src/build/Build/Products/Release/Squirrel Voice.app}"
PROFILE="${APPLE_KEYCHAIN_PROFILE:-wosaide-notary}"
DIST="$ROOT/dist"
ZIP="$DIST/SquirrelVoice-$VERSION-arm64-notary.zip"

[[ -d "$APP" ]] || { echo "App not found: $APP" >&2; exit 1; }
mkdir -p "$DIST"

codesign --verify --deep --strict --verbose=2 "$APP"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null

rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

echo "Notarized app: $APP"
