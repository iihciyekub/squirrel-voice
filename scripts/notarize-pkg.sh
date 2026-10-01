#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
PKG="${1:-$ROOT/dist/SquirrelVoice-$VERSION-arm64.pkg}"
PROFILE="${APPLE_KEYCHAIN_PROFILE:-wosaide-notary}"

notary_args=()
if [[ -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
  notary_args=(--key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
else
  notary_args=(--keychain-profile "$PROFILE")
fi

[[ -f "$PKG" ]] || { echo "PKG not found: $PKG" >&2; exit 1; }
pkgutil --check-signature "$PKG"
xcrun notarytool history "${notary_args[@]}" >/dev/null
xcrun notarytool submit "$PKG" "${notary_args[@]}" --wait
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
spctl --assess --type install --verbose=4 "$PKG"
echo "Notarized package: $PKG"
