#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP_IDENTITY="${SQUIRREL_VOICE_SIGN_IDENTITY:-Developer ID Application: Yongjian Li (2NLAH5MYH8)}"
INSTALLER_IDENTITY="${SQUIRREL_VOICE_INSTALLER_IDENTITY:-Developer ID Installer: Yongjian Li (2NLAH5MYH8)}"
PROFILE="${APPLE_KEYCHAIN_PROFILE:-wosaide-notary}"

if ! security find-identity -v -p codesigning | grep -F "\"$APP_IDENTITY\"" >/dev/null; then
  echo "Developer ID Application identity not found: $APP_IDENTITY" >&2
  exit 1
fi

echo "==> Build Squirrel Voice $VERSION with Developer ID"
SQUIRREL_VOICE_SIGN_IDENTITY="$APP_IDENTITY" "$ROOT/scripts/build-squirrel.sh"

APP="$ROOT/build/Squirrel-src/build/Build/Products/Release/Squirrel Voice.app"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Verify notary profile"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null

echo "==> Notarize app bundle"
APPLE_KEYCHAIN_PROFILE="$PROFILE" "$ROOT/scripts/notarize-app.sh" "$APP"

echo "==> Create stapled app ZIP"
"$ROOT/scripts/package-zip.sh"

echo "==> Build installer package"
if security find-identity -v -p basic | grep -F "\"$INSTALLER_IDENTITY\"" >/dev/null 2>&1; then
  SQUIRREL_VOICE_INSTALLER_IDENTITY="$INSTALLER_IDENTITY" "$ROOT/scripts/package-pkg.sh"
else
  echo "Developer ID Installer identity/private key is not available." >&2
  echo "Creating an unsigned PKG for local installation testing only." >&2
  ALLOW_UNSIGNED_PKG=1 "$ROOT/scripts/package-pkg.sh"
fi

PKG="$ROOT/dist/SquirrelVoice-$VERSION-arm64.pkg"
if pkgutil --check-signature "$PKG" 2>&1 | grep -q "Developer ID Installer"; then
  echo "==> Notarize installer package"
  APPLE_KEYCHAIN_PROFILE="$PROFILE" "$ROOT/scripts/notarize-pkg.sh" "$PKG"
else
  echo "PKG is unsigned; skipping PKG notarization. Do not publish this PKG." >&2
fi

echo "Release artifacts are in: $ROOT/dist"
