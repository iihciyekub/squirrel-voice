#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SRC="${SQUIRREL_SOURCE_DIR:-$ROOT/build/Squirrel-src}"
APP="${SQUIRREL_INSTALLED_APP:-/Library/Input Methods/Squirrel.app}"

if [[ ! -d "$APP" ]]; then
  echo "Installed Squirrel not found: $APP" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$VERSION" != "1.1.2" ]]; then
  echo "Expected installed Squirrel 1.1.2, found: ${VERSION:-unknown}" >&2
  exit 1
fi

mkdir -p "$SRC/lib/rime-plugins" "$SRC/bin" "$SRC/data/plum" "$SRC/data/opencc" "$SRC/Frameworks"

cp -p "$APP/Contents/Frameworks/librime.1.dylib" "$SRC/lib/librime.1.dylib"
cp -p "$APP/Contents/Frameworks/rime-plugins/"*.dylib "$SRC/lib/rime-plugins/"

rm -rf "$SRC/Frameworks/Sparkle.framework"
cp -R "$APP/Contents/Frameworks/Sparkle.framework" "$SRC/Frameworks/Sparkle.framework"

for tool in rime-install rime_deployer rime_dict_manager; do
  cp -p "$APP/Contents/MacOS/$tool" "$SRC/bin/$tool"
done

# Copy exactly the SharedSupport files referenced as data/plum inputs by the
# upstream Xcode project. This avoids accidentally packaging user/install state.
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  name="${rel:t}"
  source="$APP/Contents/SharedSupport/$name"
  if [[ ! -f "$source" ]]; then
    # Squirrel 1.1.2's project contains a duplicate legacy file reference for
    # detenele.schema.yaml / terra_pinyin_12345.schema.yaml. The released app
    # does not ship detenele; skip any such absent optional legacy reference.
    echo "Skipping optional SharedSupport file not present in installed app: $name"
    continue
  fi
  cp -p "$source" "$SRC/data/plum/$name"
done < <(sed -n 's/.*path = \(data\/plum\/[^;]*\);.*/\1/p' "$SRC/Squirrel.xcodeproj/project.pbxproj" | sort -u)

cp -p "$APP/Contents/SharedSupport/opencc/"* "$SRC/data/opencc/"

echo "Seeded Squirrel build inputs from installed Squirrel $VERSION"
