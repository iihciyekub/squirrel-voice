#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TEST_ROOT="$(mktemp -d -t squirrel-voice-atomic-test)"
trap 'rm -rf "$TEST_ROOT"' EXIT
xcrun clang -Wall -Wextra -Werror "$ROOT/scripts/atomic-swap.c" -o "$TEST_ROOT/swap"
xcrun swiftc "$ROOT/scripts/input-source-state.swift" -o "$TEST_ROOT/state"
/bin/mkdir -p "$TEST_ROOT/installed.app/Contents" "$TEST_ROOT/staged/Contents"
echo old > "$TEST_ROOT/installed.app/Contents/Info.plist"
echo new > "$TEST_ROOT/staged/Contents/Info.plist"
INODE="$(stat -f '%i' "$TEST_ROOT/installed.app")"

# A reader must always be able to open the installed metadata, including
# across repeated swaps. Exercise rollback by exchanging each pair twice.
python3 - "$TEST_ROOT" <<'PY'
import pathlib, subprocess, sys, threading
root = pathlib.Path(sys.argv[1])
installed = root / 'installed.app' / 'Contents'
staged = root / 'staged' / 'Contents'
stop = threading.Event()
failures = []
reads = [0]
def watch():
    while not stop.is_set():
        try:
            value = (installed / 'Info.plist').read_text().strip()
            assert value in ('old', 'new'), value
            reads[0] += 1
        except Exception as error:
            failures.append(str(error))
            break
reader = threading.Thread(target=watch)
reader.start()
try:
    for _ in range(40):
        subprocess.run([str(root / 'swap'), str(staged), str(installed)], check=True)
        assert (installed / 'Info.plist').read_text().strip() == 'new'
        subprocess.run([str(root / 'swap'), str(staged), str(installed)], check=True)
        assert (installed / 'Info.plist').read_text().strip() == 'old'
finally:
    stop.set()
    reader.join()
assert not failures, failures
assert reads[0] > 0
print(f'PASS: 40 replacements + 40 rollbacks, {reads[0]} continuous metadata reads')
PY

[[ "$(stat -f '%i' "$TEST_ROOT/installed.app")" == "$INODE" ]]
if "$TEST_ROOT/swap" "$TEST_ROOT/missing" "$TEST_ROOT/installed.app/Contents" 2>/dev/null; then
  echo "FAIL: exchanging a missing directory unexpectedly succeeded" >&2
  exit 1
fi
[[ "$(cat "$TEST_ROOT/installed.app/Contents/Info.plist")" == old ]]

# Empty snapshots must not enable/select an input source. This is safe to run
# on a developer machine and protects the fresh-install behavior.
printf '%s\n' '{"enabled":{}}' > "$TEST_ROOT/disabled.json"
"$TEST_ROOT/state" snapshot "$TEST_ROOT/before.json"
"$TEST_ROOT/state" restore "$TEST_ROOT/disabled.json" "$TEST_ROOT/installed.app"
"$TEST_ROOT/state" snapshot "$TEST_ROOT/after.json"
python3 - "$TEST_ROOT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
assert json.loads((root / 'before.json').read_text()) == json.loads((root / 'after.json').read_text())
print('PASS: fresh/disabled snapshots preserve input source state')
PY
echo "Atomic installation checks: PASS"
