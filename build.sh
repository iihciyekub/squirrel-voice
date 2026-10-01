#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
"$ROOT/scripts/bootstrap.sh"
cmake -S "$ROOT" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/build" -j "$(sysctl -n hw.logicalcpu)" --target squirrel-voice
echo "Built: $ROOT/build/squirrel-voice"
