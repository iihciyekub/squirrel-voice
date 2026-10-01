#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SRC="${SQUIRREL_SOURCE_DIR:-$ROOT/build/Squirrel-src}"
APP="${SQUIRREL_VOICE_APP:-$SRC/build/Build/Products/Release/Squirrel Voice.app}"
DST="$HOME/Library/Input Methods/Squirrel Voice.app"
LEGACY_DST="/Library/Input Methods/Squirrel Voice.app"
BACKUP_ROOT="$HOME/Library/Application Support/Squirrel Voice/Legacy Backups"
mkdir -p "${DST:h}" "$BACKUP_ROOT"

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/build-squirrel.sh"
fi

if ! codesign --verify --deep --strict "$APP"; then
  echo "Refusing to install: built Squirrel.app has an invalid signature." >&2
  exit 1
fi

"$ROOT/scripts/verify-voice-signature.sh" "$APP"

if [[ ! -x "$APP/Contents/Helpers/squirrel-voice" ]]; then
  echo "Refusing to install: bundled squirrel-voice helper is missing." >&2
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Refusing to install: microphone usage description is missing." >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/Squirrel Voice.app.backup-$STAMP-$$"
# Prepare and verify the entire replacement away from Input Methods. macOS
# must never observe a missing Info.plist/executable at the installed path.
STAGING="$(mktemp -d "$BACKUP_ROOT/.install-XXXXXXXX")"
SWAPPED=0
COMPLETED=0
cleanup() {
  if [[ "$SWAPPED" == "1" && "$COMPLETED" == "0" ]]; then
    "$STAGING/atomic-swap" "$STAGING/app/Contents" "$DST/Contents" || {
      echo "Rollback failed; preserved staging at: $STAGING" >&2
      return
    }
    echo "Restored previous app after failed installation." >&2
  fi
  /bin/rm -rf "$STAGING"
}
trap cleanup EXIT
xcrun clang "$ROOT/scripts/atomic-swap.c" -o "$STAGING/atomic-swap"
xcrun swiftc "$ROOT/scripts/input-source-state.swift" -o "$STAGING/input-source-state"
"$STAGING/input-source-state" snapshot "$STAGING/input-sources.json"
/usr/bin/ditto "$APP" "$STAGING/app"
"$ROOT/scripts/verify-voice-signature.sh" "$STAGING/app"
FRESH_INSTALL=0
if [[ -d "$LEGACY_DST" ]]; then
  LEGACY_BACKUP="$BACKUP_ROOT/Squirrel Voice.system-backup-$STAMP.app"
  pkill -f "$LEGACY_DST/Contents/MacOS/Squirrel Voice" 2>/dev/null || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$LEGACY_DST" 2>/dev/null || true
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'do shell script "/bin/mv " & quoted form of item 1 of argv & " " & quoted form of item 2 of argv & " && /usr/sbin/chown -R " & item 3 of argv & ":" & item 4 of argv & " " & quoted form of item 2 of argv with administrator privileges' \
    -e 'end run' \
    "$LEGACY_DST" "$LEGACY_BACKUP" "$(id -u)" "$(id -g)"
  echo "Migrated legacy system install to: $LEGACY_BACKUP"
fi

if [[ -d "$DST" ]]; then
  # Retain the bundle inode AND a complete Contents tree at all times.
  /usr/bin/ditto "$DST" "$BACKUP"
  pkill -f "$DST/Contents/MacOS/Squirrel Voice" 2>/dev/null || true
  sleep 1
  "$STAGING/atomic-swap" "$STAGING/app/Contents" "$DST/Contents"
  SWAPPED=1
else
  FRESH_INSTALL=1
  /bin/mv "$STAGING/app" "$DST"
fi

if ! codesign --verify --deep --strict "$DST"; then
  echo "Installed app failed signature verification." >&2
  exit 1
fi

"$ROOT/scripts/verify-voice-signature.sh" "$DST"

if [[ ! -x "$DST/Contents/Helpers/squirrel-voice" ]]; then
  echo "Installed app is missing the voice helper." >&2
  exit 1
fi

if [[ "$FRESH_INSTALL" == "1" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f -R -trusted "$DST"
fi

"$STAGING/input-source-state" restore "$STAGING/input-sources.json" "$DST"
COMPLETED=1

echo "Installed: $DST"
if [[ -d "$BACKUP" ]]; then
  echo "Backup: $BACKUP"
fi
echo "Use Command+Shift+Space while Squirrel Voice is the active input source to toggle speech input."
