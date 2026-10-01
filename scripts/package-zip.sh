#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="${SQUIRREL_VOICE_APP:-$ROOT/build/Squirrel-src/build/Build/Products/Release/Squirrel Voice.app}"
DIST="$ROOT/dist"
ZIP="$DIST/SquirrelVoice-$VERSION-arm64.zip"

[[ -d "$APP" ]] || { echo "App not found: $APP" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"

mkdir -p "$DIST"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "ZIP: $ZIP"
