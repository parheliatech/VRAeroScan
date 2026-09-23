#!/usr/bin/env bash
# Run the headless test suite. Fails on test failures AND on any script error, since
# Godot exits 0 even when a test function dies mid-way.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
godot="${GODOT:-godot}"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# Import first so class_name globals are registered on a fresh checkout.
"$godot" --headless --path "$here" --import >/dev/null 2>&1

"$godot" --headless --path "$here" --script res://tests/run_tests.gd >"$log" 2>&1
status=$?
grep -v '^Godot Engine' "$log" | grep -v '^$'

if grep -q 'SCRIPT ERROR\|Parse Error' "$log"; then
    echo "run.sh: script error during tests - treating as failure" >&2
    exit 1
fi
exit $status
