#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SRC="${SQUIRREL_SOURCE_DIR:-$ROOT/build/Squirrel-src}"
TAG="1.1.2"
REPO="https://github.com/rime/squirrel.git"

mkdir -p "${SRC:h}"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch "$TAG" "$REPO" "$SRC"
else
  git -C "$SRC" fetch --depth 1 origin "refs/tags/${TAG}:refs/tags/${TAG}" || true
fi

git -C "$SRC" reset --hard "$TAG"
git -C "$SRC" clean -fd
git -C "$SRC" apply "$ROOT/patches/squirrel-1.1.2.patch"
cp "$ROOT/integration/SquirrelVoiceBridge.swift" "$SRC/sources/SquirrelVoiceBridge.swift"

echo "Prepared patched Squirrel $TAG at: $SRC"
