#!/usr/bin/env bash
# macOS/Linux equivalent of stop-relay.ps1.
# Reliably stops the ABAP ADT relay (node) and the BTP connectivity tunnel (cf ssh),
# by matching on the real command line and killing each full process tree.
#
# WHY: these are started via nohup from a background shell, so the agent/tool only ever
# sees the launcher PID, not the actual node/cf child. Killing the launcher leaves the
# child as an orphan still holding the port. Always match by command line and kill the
# process group, as this script does.

set -uo pipefail

kill_matching() {
    local pattern="$1"
    local pids
    pids=$(pgrep -f "$pattern" || true)
    if [ -z "$pids" ]; then
        return
    fi
    for pid in $pids; do
        echo "[stop-relay] killing PID ${pid} and its process tree (pattern: ${pattern})..."
        pkill -9 -P "$pid" 2>/dev/null || true
        kill -9 "$pid" 2>/dev/null || true
    done
}

kill_matching "abap-adt-relay\.mjs"
kill_matching "cf ssh .*-L 20003:"

sleep 0.5
remaining=$(pgrep -f "abap-adt-relay\.mjs|cf ssh .*-L 20003:" || true)
if [ -n "$remaining" ]; then
    echo "[stop-relay] WARNING - still running after kill: ${remaining}"
else
    echo "[stop-relay] confirmed stopped."
fi
