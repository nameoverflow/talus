#!/bin/sh
set -eu
build/integration-fixture &
fixture=$!
manager=''
test_dir=$(mktemp -d)
trap 'if [ -n "$manager" ]; then kill "$manager" 2>/dev/null || true; fi; kill "$fixture" 2>/dev/null || true; rm -rf "$test_dir"' EXIT
sleep 1
TALUS_TEST_PID="$fixture" TALUS_CONFIG="$test_dir/config.json" build/talus &
manager=$!
sleep 2
build/integration-probe "$fixture"
