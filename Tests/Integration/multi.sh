#!/bin/sh
set -eu
build/integration-fixture &
first=$!
build/integration-fixture &
second=$!
manager=''
test_dir=$(mktemp -d)
trap 'if [ -n "$manager" ]; then kill "$manager" 2>/dev/null || true; fi; kill "$first" "$second" 2>/dev/null || true; rm -rf "$test_dir"' EXIT
sleep 1
TALUS_TEST_PID="$first,$second" TALUS_CONFIG="$test_dir/config.json" build/talus &
manager=$!
sleep 2
build/multi-probe "$first" "$second"
