#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
HELPER="$ROOT/build/squirrel-voice"
APP="$ROOT/build/Squirrel-src/build/Build/Products/Release/Squirrel Voice.app"

"$ROOT/build.sh" >/dev/null

echo "[1/4] model load"
"$HELPER" --probe >/dev/null

echo "[2/4] persistent helper protocol"
protocol="$(printf 'PING\nQUIT\n' | "$HELPER" --stdio 2>/dev/null)"
grep -qx 'READY' <<< "$protocol"
grep -qx 'PONG' <<< "$protocol"

UPSTREAM_WAV="$ROOT/.upstream/Confucius4-R2T2/resources/test.wav"
if [[ -f "$UPSTREAM_WAV" ]]; then
  echo "[3/4] native R2T2 WAV transcription"
  transcript="$("$HELPER" --wav "$UPSTREAM_WAV" --language Chinese 2>/dev/null)"
  [[ -n "${transcript//[[:space:]]/}" ]]
  echo "      $transcript"
else
  echo "[3/4] native R2T2 WAV transcription (skipped: upstream test.wav absent)"
fi

if [[ -d "$APP" ]]; then
  echo "[4/4] Squirrel Voice bundle"
  test -x "$APP/Contents/Helpers/squirrel-voice"
  /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$APP/Contents/Info.plist" >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "im.rime.inputmethod.SquirrelVoice" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :TISInputSourceID' "$APP/Contents/Info.plist")" == "im.rime.inputmethod.SquirrelVoice" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$(tr -d '[:space:]' < "$ROOT/VERSION")" ]]
  ! /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" >/dev/null 2>&1
  codesign --verify --deep --strict "$APP"
else
  echo "[4/4] Squirrel Voice bundle (skipped: app not built yet)"
fi

echo "Squirrel Voice smoke test: PASS"
