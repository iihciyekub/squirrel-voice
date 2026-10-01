#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SRC="${SQUIRREL_SOURCE_DIR:-$ROOT/build/Squirrel-src}"
APP="$SRC/build/Build/Products/Release/Squirrel Voice.app"
DST="/Library/Input Methods/Squirrel Voice.app"

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/build-squirrel.sh"
fi

if ! codesign --verify --deep --strict "$APP"; then
  echo "Refusing to install: built Squirrel.app has an invalid signature." >&2
  exit 1
fi

if [[ ! -x "$APP/Contents/Helpers/squirrel-voice" ]]; then
  echo "Refusing to install: bundled squirrel-voice helper is missing." >&2
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Refusing to install: microphone usage description is missing." >&2
  exit 1
fi

INSTALLER="$(mktemp /tmp/install-squirrel-voice.XXXXXX.sh)"
trap 'rm -f "$INSTALLER"' EXIT

cat > "$INSTALLER" <<EOF
#!/bin/sh
set -eu
SRC='$APP'
DST='$DST'
STAMP=\$(date +%Y%m%d-%H%M%S)
BACKUP="/Library/Input Methods/Squirrel Voice.app.backup-\$STAMP"
if [ -d "\$DST" ]; then
  /bin/mv "\$DST" "\$BACKUP"
fi
/usr/bin/ditto "\$SRC" "\$DST"
/usr/sbin/chown -R root:wheel "\$DST"
printf '%s\n' "\$BACKUP" > /tmp/squirrel-voice-last-backup.txt
EOF
chmod 755 "$INSTALLER"

# macOS owns the credential UI. The project never reads or handles the
# administrator password itself.
/usr/bin/osascript -e "do shell script \"$INSTALLER\" with administrator privileges"

if ! codesign --verify --deep --strict "$DST"; then
  echo "Installed app failed signature verification." >&2
  exit 1
fi

if [[ ! -x "$DST/Contents/Helpers/squirrel-voice" ]]; then
  echo "Installed app is missing the voice helper." >&2
  exit 1
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "$DST"
pkill -f '/Library/Input Methods/Squirrel Voice.app/Contents/MacOS/' 2>/dev/null || true
sleep 1
"$DST/Contents/MacOS/Squirrel Voice" --register-input-source || true
open "$DST"

echo "Installed: $DST"
if [[ -f /tmp/squirrel-voice-last-backup.txt ]]; then
  echo "Backup: $(cat /tmp/squirrel-voice-last-backup.txt)"
fi
echo "Use Command+Shift+Space while Squirrel Voice is the active input source to toggle speech input."
