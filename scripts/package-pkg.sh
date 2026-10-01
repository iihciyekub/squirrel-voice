#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="${SQUIRREL_VOICE_APP:-$ROOT/build/Squirrel-src/build/Build/Products/Release/Squirrel Voice.app}"
DIST="$ROOT/dist"
PKG="$DIST/SquirrelVoice-$VERSION-arm64.pkg"
PKG_ID="im.rime.inputmethod.SquirrelVoice.pkg"
INSTALLER_IDENTITY="${SQUIRREL_VOICE_INSTALLER_IDENTITY:-Developer ID Installer: Yongjian Li (2NLAH5MYH8)}"

[[ -d "$APP" ]] || { echo "App not found: $APP" >&2; exit 1; }
mkdir -p "$DIST"
rm -f "$PKG"

codesign --verify --deep --strict --verbose=2 "$APP"

args=(
  --component "$APP"
  --install-location "/Library/Input Methods"
  --identifier "$PKG_ID"
  --version "$VERSION"
)

if security find-identity -v -p basic | grep -F "\"$INSTALLER_IDENTITY\"" >/dev/null 2>&1; then
  args+=(--sign "$INSTALLER_IDENTITY")
  echo "Signing PKG with: $INSTALLER_IDENTITY"
elif [[ "${ALLOW_UNSIGNED_PKG:-0}" == "1" ]]; then
  echo "Developer ID Installer certificate not found; creating unsigned test PKG." >&2
else
  echo "Developer ID Installer certificate not found: $INSTALLER_IDENTITY" >&2
  echo "Create/import that certificate, or set ALLOW_UNSIGNED_PKG=1 for a local test package." >&2
  exit 2
fi

pkgbuild "${args[@]}" "$PKG"
pkgutil --check-signature "$PKG" || true
shasum -a 256 "$PKG"
echo "Package: $PKG"
