#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
PKG="${1:-$ROOT/dist/SquirrelVoice-$VERSION-arm64.pkg}"
PROFILE="${APPLE_KEYCHAIN_PROFILE:-wosaide-notary}"

[[ -f "$PKG" ]] || { echo "PKG not found: $PKG" >&2; exit 1; }
pkgutil --check-signature "$PKG"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
spctl --assess --type install --verbose=4 "$PKG"
echo "Notarized package: $PKG"
