#!/usr/bin/env bash
# Opens the BTP connectivity tunnel for an on-premise ABAP system.
# macOS/Linux equivalent of open-connectivity-tunnel.ps1.
# Idempotent-ish: safe to re-run; if the tunnel is already up it will just open another
# cf ssh process (kill old ones manually with stop-relay.sh if restarting).
#
# Requires the Cloud Foundry CLI ('cf') on PATH, or CF_EXE env var pointing to it.
# On macOS: brew install cloudfoundry-cli
#
# Set APP_NAME / REMOTE_HOST below (or export CF_APP_NAME / CONNECTIVITY_PROXY_HOST)
# for your own BTP app and region. APP_NAME is a BTP app bound to the connectivity
# service in your subaccount; REMOTE_HOST is that region's connectivity proxy host
# (connectivityproxy.internal.cf.<region>.hana.ondemand.com).

set -euo pipefail

CF_EXE="${CF_EXE:-cf}"
APP_NAME="${CF_APP_NAME:-<YOUR_CF_APP_NAME>}"
REMOTE_HOST="${CONNECTIVITY_PROXY_HOST:-<YOUR_CONNECTIVITY_PROXY_HOST>}"
REMOTE_PORT=20003
LOCAL_PORT=20003

if [ "$APP_NAME" = "<YOUR_CF_APP_NAME>" ] || [ "$REMOTE_HOST" = "<YOUR_CONNECTIVITY_PROXY_HOST>" ]; then
    echo "[tunnel] ERROR - set APP_NAME/REMOTE_HOST in this script (or export CF_APP_NAME/CONNECTIVITY_PROXY_HOST) before running it."
    exit 1
fi

echo "[tunnel] opening cf ssh -L ${LOCAL_PORT}:${REMOTE_HOST}:${REMOTE_PORT} via ${APP_NAME} ..."
nohup "$CF_EXE" ssh "$APP_NAME" -N -L "${LOCAL_PORT}:${REMOTE_HOST}:${REMOTE_PORT}" \
    > /tmp/abap-adt-tunnel.log 2>&1 &
disown

sleep 3
if nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null; then
    echo "[tunnel] up: 127.0.0.1:${LOCAL_PORT} -> ${REMOTE_HOST}:${REMOTE_PORT}"
else
    echo "[tunnel] WARNING - could not confirm port ${LOCAL_PORT} yet, check /tmp/abap-adt-tunnel.log"
fi
