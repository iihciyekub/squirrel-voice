#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
LLAMA_DIR="$ROOT/third_party/llama.cpp"
LLAMA_COMMIT="ad6c66839af3c5646fba8c6c2e2087a1e4e38948"

mkdir -p "$ROOT/third_party"
if [[ ! -d "$LLAMA_DIR/.git" ]]; then
  git init "$LLAMA_DIR"
  git -C "$LLAMA_DIR" remote add origin https://github.com/ggml-org/llama.cpp.git
fi

if [[ "$(git -C "$LLAMA_DIR" rev-parse HEAD 2>/dev/null || true)" != "$LLAMA_COMMIT" ]]; then
  git -C "$LLAMA_DIR" fetch --depth 1 origin "$LLAMA_COMMIT"
  git -C "$LLAMA_DIR" checkout --detach FETCH_HEAD
fi

echo "llama.cpp pinned: $(git -C "$LLAMA_DIR" rev-parse --short HEAD)"
