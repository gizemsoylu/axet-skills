#!/usr/bin/env bash
# macOS/Linux equivalent of start-relay.ps1.
# Loads agent-dir/sap_cred.env into the environment and launches the relay in the background.
# Copy sap_cred.env.example to sap_cred.env and fill in your own values first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/sap_cred.env"
set +a

export AGENT_DIR="$SCRIPT_DIR"
export PERSONAL_SAP_USER="$SAP_USER"
export PERSONAL_SAP_PASSWORD="$SAP_PASS"
export RELAY_PORT="4599"
export CF_EXE="${CF_EXE:-cf}"

nohup node "$SCRIPT_DIR/scripts/abap-adt-relay.mjs" > /tmp/abap-adt-relay.log 2>&1 &
RELAY_PID=$!
disown
echo "[relay] started in background, pid=${RELAY_PID} (log: /tmp/abap-adt-relay.log)"
