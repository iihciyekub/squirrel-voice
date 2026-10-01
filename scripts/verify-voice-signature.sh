#!/bin/zsh
set -euo pipefail

APP="${1:?Usage: verify-voice-signature.sh APP}"
codesign --verify --deep --strict "$APP"
ENTITLEMENTS="$(mktemp -t squirrel-voice-entitlements)"
trap 'rm -f "$ENTITLEMENTS"' EXIT

# A valid signature alone does not grant microphone access. TCC checks both
# the responsible input method and the helper that actually records audio.
for TARGET in "$APP" "$APP/Contents/Helpers/squirrel-voice"; do
  codesign -d --entitlements - --xml "$TARGET" > "$ENTITLEMENTS" 2>/dev/null
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS" 2>/dev/null || true)" != "true" ]]; then
    echo "Missing microphone audio-input entitlement: $TARGET" >&2
    exit 1
  fi
done
