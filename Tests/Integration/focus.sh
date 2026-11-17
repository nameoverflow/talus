#!/bin/sh
set -eu
first=''
second=''
cleanup() {
    if [ -n "$first" ]; then kill "$first" 2>/dev/null || true; wait "$first" 2>/dev/null || true; fi
    if [ -n "$second" ]; then kill "$second" 2>/dev/null || true; wait "$second" 2>/dev/null || true; fi
}
trap cleanup EXIT
build/integration-fixture &
first=$!
build/integration-fixture &
second=$!
sleep 0.5
build/focus-probe/probe "$first" "$second"
