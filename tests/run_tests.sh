#!/usr/bin/env bash
# GODOT_BIN=/path/to/Godot ./tests/run_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT_BIN="${GODOT_BIN:-godot}"
runtime="$(mktemp -d "${TMPDIR:-/tmp}/tankbattle-tests.XXXXXX")"
trap 'rm -rf "$runtime"' EXIT
mkdir -p "$runtime"/{data,cache,config}
set +e
XDG_DATA_HOME="$runtime/data" XDG_CACHE_HOME="$runtime/cache" XDG_CONFIG_HOME="$runtime/config" \
  "$GODOT_BIN" --headless --path . --script res://tests/test_battle.gd >"$runtime/output.log" 2>&1
status=$?
set -e
cat "$runtime/output.log"
if [[ $status -ne 0 ]] || grep -Eq 'SCRIPT ERROR|^ERROR:|FAIL:' "$runtime/output.log" || ! grep -Eq 'TANK_BATTLE_TESTS: [0-9]+ checks, 0 failures' "$runtime/output.log"; then
  exit 1
fi
