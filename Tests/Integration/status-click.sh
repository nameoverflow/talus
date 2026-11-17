#!/bin/sh
set -eu
test_dir=$(mktemp -d)
fixture=''
cleanup() {
    if [ -n "$fixture" ]; then kill "$fixture" 2>/dev/null || true; wait "$fixture" 2>/dev/null || true; fi
    rm -rf "$test_dir"
}
trap cleanup EXIT
binary=build/StatusClickProbe.app/Contents/MacOS/Probe
"$binary" --fixture "$test_dir/state.json" &
fixture=$!
for i in $(seq 1 100); do
    if [ -s "$test_dir/state.json" ]; then break; fi
    sleep 0.05
done
test -s "$test_dir/state.json" || { echo 'Status click fixture is not visible'; exit 1; }
"$binary" --probe "$test_dir/state.json"
