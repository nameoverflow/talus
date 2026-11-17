#!/bin/sh
set -eu
test_dir=$(mktemp -d)
fixture=''
manager=''
cleanup() {
    if [ -n "$manager" ]; then kill "$manager" 2>/dev/null || true; wait "$manager" 2>/dev/null || true; fi
    if [ -n "$fixture" ]; then kill "$fixture" 2>/dev/null || true; wait "$fixture" 2>/dev/null || true; fi
    rm -rf "$test_dir"
}
trap cleanup EXIT
python3 - "$test_dir" <<'PY'
import json, pathlib, sys
directory = pathlib.Path(sys.argv[1])
(directory/'config.json').write_text(json.dumps({
    'workspaceMode': 'virtual', 'workspaceCount': 3,
    'modifiers': ['control', 'option', 'command'],
    'statusStateFile': str(directory/'status.json'),
}))
PY
build/integration-fixture &
fixture=$!
sleep 0.5
TALUS_TEST_PID="$fixture" TALUS_TEST_HOTKEYS=1 TALUS_TRACE_EVENTS=1 \
    TALUS_SESSION_FILE="$test_dir/session.json" TALUS_CONFIG="$test_dir/config.json" \
    "${TALUS_BIN:-build/talus}" &
manager=$!
build/virtual-responsiveness-probe "$fixture" "$test_dir/status.json"
kill -TERM "$manager"
wait "$manager"
manager=''
build/virtual-responsiveness-probe "$fixture" "$test_dir/status.json" --restored
python3 - "$test_dir/session.json" <<'PY'
import json, pathlib, sys
snapshot = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert snapshot['activeWorkspace'] == 0
assert sum(map(len, snapshot['workspaceWindowIDs'])) == 3
print('Exit flushed the final virtual workspace session')
PY
