---
name: abap-adt-relay
description: Use when the user wants to start, stop, restart, or verify a local ABAP ADT relay and BTP connectivity tunnel so ADT-based tooling (e.g. an MCP ABAP ADT server) can reach an on-premise SAP system through aXet.code, or when they report ADT calls failing with 401/502/ECONNREFUSED through that relay.
---

# ABAP ADT Relay (via BTP Connectivity Service)

## When to use this skill

Use this skill whenever the user asks to:
- "start/stop/restart the ADT relay" or "the SAP relay"
- "open the connectivity tunnel" to an on-premise ABAP system
- debug why ADT calls through the relay return 401 (Unauthorized), 502 (Bad
  Gateway) / `ECONNREFUSED 127.0.0.1:20003`, or appear to hang
- verify the relay is working before using an ADT-based MCP server

The relay lets a plain HTTP-based ADT client (any MCP ADT server included)
reach an on-premise ABAP system through the SAP BTP Connectivity service,
authenticating as a **personal SAP user** instead of a destination's own
service user (useful when that service user has no ADT/SICF authorization).

## Architecture

```
ADT client / MCP server
      |  HTTP, Basic Auth stripped+replaced
      v
127.0.0.1:4599  (local Node relay: abap-adt-relay.mjs)
      |  SAP Cloud SDK executeHttpRequest(), personal user credentials
      v
127.0.0.1:20003 (local port, forwarded by `cf ssh -L` tunnel)
      |
      v
BTP Connectivity Proxy  --(on-premise cloud connector)-->  SAP backend (ADT/SICF)
```

Two local processes must both be running at the same time:
1. **Connectivity tunnel** — `cf ssh <app> -N -L 20003:<proxy-host>:20003`
2. **Relay** — a Node HTTP server on port 4599 that resolves the BTP
   destination, swaps in the personal user's credentials, and forwards every
   request/response.

## One-time setup (per developer machine)

See `agent-dir-template/` in this repo — copy that whole folder into your
own project as `agent-dir/` and fill in the blanks. Full checklist with
exact verification commands: `SETUP.md` at the repo root.

Required on PATH (or pointed to via env var):
- `node` (any LTS version with global fetch/`node:` imports)
- Cloud Foundry CLI `cf` (or set `CF_EXE` to its full path)
- A local CAP/Node project already bound to the BTP subaccount's
  `connectivity` service in hybrid mode (`.cdsrc-private.json` with a
  `requires.[hybrid].connectivity.credentials` block) and with
  `@sap-cloud-sdk/connectivity` + `@sap-cloud-sdk/http-client` installed —
  `agent-dir-template/package.json` lists the exact versions.
- A personal SAP user/password with ADT authorization on the target system,
  stored only in `agent-dir/sap_cred.env` (never committed — see
  `.gitignore`).

## Day-to-day commands

From the `agent-dir/` folder (Windows / PowerShell):
```powershell
./scripts/open-connectivity-tunnel.ps1   # 1. open the tunnel, confirms port 20003
./start-relay.ps1                        # 2. start the relay, confirms port 4599
./scripts/stop-relay.ps1                 # stop both (tunnel + relay), by port ownership
```
macOS/Linux: use the matching `.sh` scripts.

`start-relay.ps1` starts Node detached with stdin/stdout/stderr redirected
to `relay.log` / `relay.err.log` / `relay.stdin` and returns immediately —
it does not block the calling shell.

## Verifying it works

```powershell
Invoke-WebRequest -Uri 'http://127.0.0.1:4599/sap/bc/adt/discovery' -UseBasicParsing
```
- **200 + XML body** → relay + tunnel + credentials are all correct.
- **502 Bad Gateway**, body `connect ECONNREFUSED 127.0.0.1:20003` → the
  tunnel is down. Re-run `open-connectivity-tunnel.ps1` (it can silently die
  if the underlying `cf ssh` session drops — check with
  `Get-NetTCPConnection -LocalPort 20003`).
- **401 Unauthorized**, SAP login page HTML (e.g. `Anmeldung fehlgeschlagen`
  for German-locale systems) → tunnel/relay are fine, but `SAP_USER`/
  `SAP_PASS` in `sap_cred.env` are wrong/expired for that backend. Fix the
  credentials, no code change needed.
- **400 Bad Request** from the SAP side (not the relay) → usually a
  malformed/forbidden ADT request, not a relay problem.

## Troubleshooting process hygiene (Windows)

- These processes are started detached (`Start-Process -NoNewWindow` /
  background shell), so a tool or terminal only ever sees the **launcher**
  PID, not the real `node.exe`/`cf.exe` child. Killing just the launcher
  leaves the real process as an orphan still holding its port.
- Always resolve PIDs by **port ownership** (`Get-NetTCPConnection -LocalPort
  4599,20003`), not by scanning `Get-CimInstance Win32_Process` command
  lines — WMI queries can hang on some machines with no timeout.
  `scripts/stop-relay.ps1` already does this correctly and runs under a
  hard timeout; prefer it over ad-hoc one-liners.
- If `start-relay.ps1`'s `Start-Process -NoNewWindow` is ever changed to
  **not** redirect stdin/stdout/stderr, the child inherits this session's
  console pipe handles. Since the relay never exits on its own, that pipe
  never reaches EOF — which then hangs *any later command* run in the same
  session (not just relay-related ones), because it waits on that same
  handle. Keep all three streams redirected to files.
