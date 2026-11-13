#!/bin/sh
set -eu
test_dir=$(mktemp -d)
manager=''
child=''
trap 'if [ -n "$manager" ]; then kill "$manager" 2>/dev/null || true; fi; if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; fi; rm -rf "$test_dir"' EXIT
printf '%s' '{"statusTemplate":"%slow%","statusCommands":[{"name":"slow","executable":"/bin/sleep","arguments":["30"],"interval":60,"timeout":10}]}' > "$test_dir/config.json"
TALUS_TEST_PID=0 TALUS_CONFIG="$test_dir/config.json" build/talus > "$test_dir/log" 2>&1 &
manager=$!
sleep 1
child=$(pgrep -P "$manager" | head -1)
if [ -z "$child" ]; then echo 'No command child was found'; exit 1; fi
kill -TERM "$manager"
wait "$manager"
manager=''
if kill -0 "$child" 2>/dev/null; then echo 'Command remained after Talus exit'; exit 1; fi
child=''
echo 'Configured command exited with Talus'
