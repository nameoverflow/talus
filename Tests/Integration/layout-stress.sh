#!/bin/sh
set -eu
test_dir=$(mktemp -d)
first=''; second=''; click=''; manager=''; recorder=''
cleanup() {
    if [ -n "$recorder" ]; then kill -INT "$recorder" 2>/dev/null || true; wait "$recorder" 2>/dev/null || true; fi
    if [ -n "$first" ]; then kill -CONT "$first" 2>/dev/null || true; fi
    if [ -n "$second" ]; then kill -CONT "$second" 2>/dev/null || true; fi
    if [ -n "$manager" ]; then kill -TERM "$manager" 2>/dev/null || true; wait "$manager" 2>/dev/null || true; fi
    for fixture in "$first" "$second" "$click"; do
        if [ -n "$fixture" ]; then kill "$fixture" 2>/dev/null || true; wait "$fixture" 2>/dev/null || true; fi
    done
    rm -rf "$test_dir"
}
trap cleanup EXIT
python3 - "$test_dir" <<'PY'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
(d/'config.json').write_text(json.dumps({
    'workspaceMode': 'virtual', 'workspaceCount': 3,
    'masterRatio': 0.5, 'ratioStep': 0.01,
    'modifiers': ['control', 'option', 'command'],
    'statusStateFile': str(d/'status.json'),
}))
PY
build/integration-fixture &
first=$!
build/integration-fixture &
second=$!
build/click-fixture &
click=$!
sleep 0.5
TALUS_TEST_PID="$first,$second" TALUS_TEST_HOTKEYS=1 TALUS_TRACE_EVENTS=1 \
    TALUS_SESSION_FILE="$test_dir/session.json" TALUS_CONFIG="$test_dir/config.json" \
    "${TALUS_BIN:-build/talus}" &
manager=$!
if [ -n "${TALUS_STRESS_VIDEO:-}" ]; then
    TALUS_STRESS_RECORDING=1 build/layout-stress/probe "$first" "$second" "$click" "$test_dir" &
    probe=$!
    for attempt in $(seq 1 80); do
        if [ -f "$test_dir/record-ready" ]; then break; fi
        sleep 0.05
    done
    test -f "$test_dir/record-ready"
    screencapture -x -v -V 6 -R0,34,1710,1073 "$TALUS_STRESS_VIDEO" &
    recorder=$!
    sleep 0.5
    touch "$test_dir/record-go"
    wait "$probe"
else
    build/layout-stress/probe "$first" "$second" "$click" "$test_dir"
fi
kill -TERM "$manager"
wait "$manager"
manager=''
build/layout-stress/probe "$first" "$second" "$click" "$test_dir" --restored
if [ -n "$recorder" ]; then wait "$recorder"; recorder=''; fi
