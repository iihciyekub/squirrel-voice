#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
PKG="${1:-$ROOT/dist/SquirrelVoice-$VERSION-arm64.pkg}"
OUT="${2:-$ROOT/dist/squirrel-voice.rb}"
BASE="${SQUIRREL_VOICE_RELEASE_BASE_URL:-https://github.com/OWNER/REPO/releases/download}"
HOME="${SQUIRREL_VOICE_HOMEPAGE:-https://github.com/OWNER/REPO}"

[[ -f "$PKG" ]] || { echo "PKG not found: $PKG" >&2; exit 1; }
SHA="$(shasum -a 256 "$PKG" | awk '{print $1}')"
mkdir -p "${OUT:h}"
sed \
  -e "s|@VERSION@|$VERSION|g" \
  -e "s|@SHA256@|$SHA|g" \
  -e "s|@RELEASE_BASE_URL@|$BASE|g" \
  -e "s|@HOMEPAGE@|$HOME|g" \
  "$ROOT/homebrew/Casks/squirrel-voice.rb.in" > "$OUT"
echo "Cask: $OUT"
