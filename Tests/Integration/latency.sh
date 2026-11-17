#!/bin/sh
set -eu
test_dir=$(mktemp -d)
build/event-fixture "$test_dir/started" &
fixture=$!
manager=''
trap 'if [ -n "$manager" ]; then kill "$manager" 2>/dev/null || true; wait "$manager" 2>/dev/null || true; fi; kill "$fixture" 2>/dev/null || true; wait "$fixture" 2>/dev/null || true; rm -rf "$test_dir"' EXIT
sleep 0.5
TALUS_TRACE_EVENTS=1 TALUS_TEST_PID="$fixture" TALUS_CONFIG="$test_dir/config.json" "${TALUS_BIN:-build/talus}" &
manager=$!
build/event-probe "$fixture" "$test_dir/started"
