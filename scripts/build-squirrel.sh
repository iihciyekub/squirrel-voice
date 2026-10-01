#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SRC="${SQUIRREL_SOURCE_DIR:-$ROOT/build/Squirrel-src}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="${SQUIRREL_VOICE_BUILD_NUMBER:-1}"
PRODUCT_NAME="Squirrel Voice"
BUNDLE_ID="im.rime.inputmethod.SquirrelVoice"

"$ROOT/build.sh"
"$ROOT/scripts/prepare-squirrel.sh"

echo "Building Squirrel 1.1.2 + Voice bridge..."
# Squirrel 1.1.2 officially supports macOS 13+. Pinning this matters on newer
# Xcode SDKs: several old librime dependencies otherwise configure themselves
# for macOS 10.15 and libc++ turns the unsupported-target warning into -Werror.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
if [[ -z "${BOOST_ROOT:-}" ]] && command -v brew >/dev/null 2>&1; then
  BOOST_ROOT="$(brew --prefix boost 2>/dev/null || true)"
  [[ -n "$BOOST_ROOT" ]] && export BOOST_ROOT
fi

INSTALLED_APP="${SQUIRREL_INSTALLED_APP:-/Library/Input Methods/Squirrel.app}"
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "${SQUIRREL_USE_UPSTREAM_PREBUILT:-0}" == "1" ]]; then
  echo "Using upstream Squirrel 1.1.2 CI dependency artifacts..."
  # Upstream Actions checks Squirrel out with submodules enabled. The binary
  # dependency archive supplies librime itself, but Xcode still consumes public
  # headers from librime/src through the bridging header, so keep the pinned
  # librime source submodule available without rebuilding it.
  git -C "$SRC" submodule update --init --depth 1 librime
  (
    cd "$SRC"
    # action-install.sh copies a versioned Sparkle framework with symlinks.
    # Remove any previous extracted/copied runtime first so repeated local/CI
    # builds cannot merge two framework layouts and corrupt those symlinks.
    rm -rf download Frameworks/Sparkle.framework librime/dist data/plum plum/output
    # Squirrel's Xcode project contains references to the standard Rime preset
    # schemas (bopomofo/cangjie/luna-pinyin/stroke/terra-pinyin). Install the
    # canonical Plum preset explicitly on clean machines, then layer the same
    # octagram data used by Squirrel 1.1.2's upstream release workflow.
    export SQUIRREL_BUNDLED_RECIPES="${SQUIRREL_BUNDLED_RECIPES:-:preset lotem/rime-octagram-data lotem/rime-octagram-data@hant}"
    ./action-install.sh
  )
elif [[ "${SQUIRREL_REBUILD_DEPS:-0}" != "1" && "$INSTALLED_VERSION" == "1.1.2" ]]; then
  echo "Reusing native dependencies from installed Squirrel 1.1.2..."
  "$ROOT/scripts/seed-installed-squirrel-deps.sh"

  # The Sparkle framework embedded in the installed app is distribution-
  # stripped and has no Modules/module.modulemap, so Swift cannot import it
  # while recompiling Squirrel. Build only the pinned Sparkle submodule; this
  # is independent of librime/OpenCC/Boost and is fast on subsequent runs.
  if [[ ! -f "$SRC/Sparkle/build/Release/Sparkle.framework/Versions/B/Modules/module.modulemap" ]]; then
    git -C "$SRC" submodule update --init --depth 1 Sparkle
    xcodebuild \
      -project "$SRC/Sparkle/Sparkle.xcodeproj" \
      -configuration Release \
      ARCHS=arm64 \
      ONLY_ACTIVE_ARCH=NO \
      MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
      CODE_SIGNING_ALLOWED=NO \
      build
  fi
  rm -rf "$SRC/Frameworks/Sparkle.framework"
  cp -R "$SRC/Sparkle/build/Release/Sparkle.framework" "$SRC/Frameworks/Sparkle.framework"

else
  echo "Initializing and rebuilding Squirrel native dependencies..."
  git -C "$SRC" submodule update --init --recursive --depth 1

  # CMake only reads MACOSX_DEPLOYMENT_TARGET when a build tree is first
  # configured. Drop stale dependency caches that were created with another
  # target, otherwise a retry can keep compiling for an obsolete macOS version.
  for cache in "$SRC"/librime/deps/*/build/CMakeCache.txt(N); do
    cached="$(sed -n 's/^CMAKE_OSX_DEPLOYMENT_TARGET:STRING=//p' "$cache" | head -1)"
    if [[ -n "$cached" && "$cached" != "$MACOSX_DEPLOYMENT_TARGET" ]]; then
      echo "Resetting stale dependency cache (${cached} -> ${MACOSX_DEPLOYMENT_TARGET}): ${cache:h}"
      rm -rf "${cache:h}"
    fi
  done

  # OpenCC in the Squirrel 1.1.2 dependency graph still uses FindPythonInterp.
  # Seed its CMake cache with the system Python explicitly so current CMake
  # versions do not fail discovery while generating dictionary data.
  OPENCC="$SRC/librime/deps/opencc"
  if [[ -f "$OPENCC/CMakeLists.txt" ]]; then
    cmake -S "$OPENCC" -B "$OPENCC/build" \
      -DBUILD_SHARED_LIBS:BOOL=OFF \
      -DCMAKE_BUILD_TYPE:STRING=Release \
      -DCMAKE_INSTALL_PREFIX:PATH="$SRC/librime" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING="$MACOSX_DEPLOYMENT_TARGET" \
      -DPYTHON_EXECUTABLE:FILEPATH="$(xcrun -f python3)"
  fi
  make -C "$SRC" deps ARCHS=arm64 MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
  make -C "$SRC" sparkle ARCHS=arm64 MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
fi

mkdir -p "$SRC/build"
(
  cd "$SRC"
  # Upstream's helper starts dynamic PBX IDs at 81/82, which are already
  # occupied by detenele in the 1.1.2 project. Move this temporary build-time
  # allocator forward so repeated local builds remain a valid Xcode project.
  sed -i '' 's/^lastid=80$/lastid=90/' package/add_data_files
  bash package/add_data_files
  xcodebuild \
    -project Squirrel.xcodeproj \
    -configuration Release \
    -scheme Squirrel \
    -derivedDataPath build \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGNING_ALLOWED=NO \
    PRODUCT_NAME="$PRODUCT_NAME" \
    PRODUCT_MODULE_NAME=Squirrel \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    INFOPLIST_KEY_CFBundleDisplayName="$PRODUCT_NAME" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build
)

APP="$SRC/build/Build/Products/Release/$PRODUCT_NAME.app"
if [[ ! -d "$APP" ]]; then
  echo "Squirrel build did not produce: $APP" >&2
  exit 1
fi

HELPERS="$APP/Contents/Helpers"
mkdir -p "$HELPERS"
cp "$ROOT/build/squirrel-voice" "$HELPERS/squirrel-voice"
chmod 755 "$HELPERS/squirrel-voice"

# Local development signing by default. Release builds provide a Developer ID
# through SQUIRREL_VOICE_SIGN_IDENTITY and get Hardened Runtime + timestamp.
IDENTITY="${SQUIRREL_VOICE_SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$HELPERS/squirrel-voice"
  codesign --force --deep --sign - "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$HELPERS/squirrel-voice"
  codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements "$SRC/resources/Squirrel.entitlements" "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built patched app: $APP"
