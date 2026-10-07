---
name: abap-adt-relay
description: Use when the user wants to start, stop, restart, or verify a local ABAP ADT relay and BTP connectivity tunnel so ADT-based tooling (e.g. an MCP ABAP ADT server) can reach an on-premise SAP system (e.g. S25) through aXet.code, or when they report ADT calls failing with 401/502/ECONNREFUSED through that relay.
---

# ABAP ADT Relay (via BTP Connectivity Service)

## When to use this skill

Use this skill whenever the user asks to:
- "start/stop/restart the ADT relay" or "the SAP relay" (e.g. for the S25 system)
- "open the connectivity tunnel" to an on-premise ABAP system
- debug why ADT calls through the relay return 401 (Unauthorized), 502 (Bad
  Gateway) / `ECONNREFUSED 127.0.0.1:20003`, or appear to hang
- verify the relay is working before using an ADT-based MCP server

The relay lets a plain HTTP-based ADT client (any MCP ADT server included)
reach an on-premise ABAP system (this project targets the **S25** on-premise
system) through the SAP BTP Connectivity service, authenticating as a
**personal SAP user** instead of a destination's own service user (useful
when that service user has no ADT/SICF authorization).

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
BTP Connectivity Proxy  --(on-premise cloud connector)-->  SAP backend S25 (ADT/SICF)
```

Two local processes must both be running at the same time:
1. **Connectivity tunnel** — `cf ssh <app> -N -L 20003:<proxy-host>:20003`
2. **Relay** — a Node HTTP server on port 4599 that resolves the BTP
   destination (`S25`), swaps in the personal user's credentials, and
   forwards every request/response.

## One-time setup (per developer machine)

This project's `agent-dir/` folder already contains the relay runtime —
fill in the blanks before first use. Full checklist with exact verification
commands: `agent-dir/SETUP.md`.

Required on PATH (or pointed to via env var):
- `node` (any LTS version with global fetch/`node:` imports)
- Cloud Foundry CLI `cf` (or set `CF_EXE` to its full path)
- A local CAP/Node project already bound to the BTP subaccount's
  `connectivity` service in hybrid mode (`.cdsrc-private.json` with a
  `requires.[hybrid].connectivity.credentials` block) and with
  `@sap-cloud-sdk/connectivity` + `@sap-cloud-sdk/http-client` installed —
  `agent-dir/package.json` lists the exact versions.
- A personal SAP user/password with ADT authorization on S25, stored only
  in `agent-dir/sap_cred.env` (never committed — see `.gitignore`).
- The BTP destination name for S25 set as `S4_DEST` in `agent-dir/sap_cred.env`.

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
  for German-locale systems) → first suspect `SAP_USER`/`SAP_PASS` in
  `sap_cred.env` being wrong/expired for S25 (fix the credentials, no code
  change needed). **But** if credentials are confirmed correct and it still
  401s, check whether the relay is actually sending Basic Auth at all: in
  `scripts/abap-adt-relay.mjs`, overriding only `username`/`password` on the
  destination object (`{ ...baseDestination, username, password }`) is **not
  enough** — if the BTP destination itself isn't configured with
  `authentication=BasicAuthentication` (e.g. it's `NoAuthentication` or
  `PrincipalPropagation`), the SAP Cloud SDK never adds an `Authorization`
  header at all, and the backend sees it as an anonymous request → 401. Fix:
  also force `authentication: 'BasicAuthentication'` on the destination
  override, e.g.:
  ```js
  const destination = {
    ...baseDestination,
    authentication: 'BasicAuthentication',
    username: PERSONAL_USER,
    password: PERSONAL_PASSWORD,
  };
  ```
  This is already applied in this project's `scripts/abap-adt-relay.mjs` —
  if a future refactor reverts it, this is the symptom to look for.
- **ETIMEDOUT / every request hangs ~20s then fails, DNS override log line
  (`[relay] DNS override: ... -> 127.0.0.1`) never appears** → the relay's
  `CONNECTIVITY_PROXY_HOST` env var (used by `start-relay.ps1`/
  `_start_relay_https_tmp.ps1`, default
  `connectivityproxy.internal.cf.eu10-005.hana.ondemand.com`) must be the
  **exact same string** as the `onpremise_proxy_host` value inside
  `AGENT_DIR/.cdsrc-private.json`'s `requires.[hybrid].connectivity.credentials`
  — that JSON value is what the SAP Cloud SDK actually dials, and the relay's
  `dns.lookup` patch (`scripts/abap-adt-relay.mjs`) only redirects-to-127.0.0.1
  the literal hostname it was given via `CONNECTIVITY_PROXY_HOST`. If the two
  differ (e.g. `.cdsrc-private.json` was regenerated/rebound against a
  different connectivity instance, or someone edited one but not the other),
  the SDK resolves the *real* internal-only CF address instead of localhost
  and every call stalls until it times out. **Do not print `.cdsrc-private.json`'s
  contents to check this** (it's a secrets file, see "Credential handling"
  below) — compare the two values as a boolean only, e.g.:
  ```powershell
  $cdsrcHost = (Get-Content "$AgentDir/.cdsrc-private.json" | ConvertFrom-Json).requires.'[hybrid]'.connectivity.credentials.onpremise_proxy_host
  Write-Host ("MATCH: " + ($cdsrcHost -eq $env:CONNECTIVITY_PROXY_HOST))
  ```
  Also make sure `open-connectivity-tunnel.ps1`'s `$RemoteHost` (same env var)
  matches too, otherwise the tunnel is forwarding a different host/port than
  the one the relay is told to patch.
- **400 Bad Request** from the SAP side (not the relay) → usually a
  malformed/forbidden ADT request, not a relay problem.
- **503 Server Unavailable**, body mentions "no SAP Cloud Connector (SCC)
  connected to your subaccount matching the requested tunnel ... location
  ID ..." → tunnel + relay + credentials are all correct on this machine;
  the on-premise **Cloud Connector** for that location ID is down or not
  paired with the BTP subaccount. This is infra-side, not fixable from the
  relay/tunnel scripts — check `relay.log` for the exact SCC location ID
  and destination, then have whoever administers the Cloud Connector
  verify it's running and connected for that subaccount/location.

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

## Credential handling (strict)

- `agent-dir/sap_cred.env` (and `agent-dir/.cdsrc-private.json`) hold a
  personal SAP username/password and connectivity-service secrets. Treat
  them as secrets end to end.
- **Never read/view/cat these files or print their contents in chat**,
  even to "verify" a value. This explicitly includes the agent's own `view`
  tool (or any file-read tool) on `sap_cred.env` / `.cdsrc-private.json` —
  do not open them "just to check a field name" or "just to confirm a host
  value" either; the whole file content would be surfaced in the
  conversation either way. If you need to check a variable is set, check
  for presence only (e.g. `Test-Path` or `[bool]$env:SAP_PASS`), or compare
  a single derived value as a boolean (see the 127.0.0.1/`CONNECTIVITY_PROXY_HOST`
  troubleshooting entry above for an example), never the raw value itself.
- **Never commit or push these files to git/GitHub.** `agent-dir/.gitignore`
  already excludes `sap_cred.env`, `.cdsrc-private.json`, `relay.log`,
  `relay.err.log`, `relay.stdin` and the `tools/cf*.exe` binaries — do not
  remove or bypass those entries, and double-check `git status`/`git diff`
  never stage them before any commit in this repo.
- Logs (`relay.log`, `relay.err.log`) can echo request/response bodies;
  don't paste their contents into chat either without checking they're
  free of credentials/tokens first.

## Never block waiting on these jobs

The tunnel and the relay are **never-exiting** processes by design (a
long-lived `cf ssh -N -L ...` tunnel and a Node HTTP server). Treat any
background job running them as a daemon, not a task to wait for:

- **Never call `job_output` with `wait=true`** (or any blocking/foreground
  equivalent) on the tunnel or relay job. It will hang forever because the
  job is never meant to finish — that is not a bug, it's expected.
- After starting either script in the background, call `job_output` once
  with `wait=false` just to confirm the one-line "started"/"listening"
  message, then stop polling it.
- To actually verify the relay+tunnel are healthy, don't inspect the job
  output at all — use the HTTP check in "Verifying it works" above
  (`Invoke-WebRequest .../sap/bc/adt/discovery`). That's the real
  source of truth, not the job's stdout stream.
- If a terminal looks "stuck" waiting on one of these jobs, the fix is to
  cancel that specific blocking call (e.g. `esc`), not to kill or restart
  the relay/tunnel — they are still fine.

## Windows background-launch note (bash tool)

When starting `start-relay.ps1` (or `open-connectivity-tunnel.ps1`) through
a sandboxed bash tool on Windows, **always run it as a background job**
(e.g. the tool's `run_in_background` option), never in the foreground.
Even though both scripts redirect the child's stdio and return immediately
on their own, a foreground invocation can still hang indefinitely: the
sandbox's shell wraps the launch in a Windows Job Object to track/kill
subprocesses, and `node.exe`/`cf.exe` — a never-exiting server/tunnel — can
stay attached to that same job, so the tool waits for the job to go empty
instead of just for the launcher script to exit. Running it in the
background sidesteps this; use `job_output` to confirm the one-line
"started" message instead of waiting on the foreground call.

## Source

Extracted and adapted from https://github.com/gizemsoylu/axet-skills
(`skills/abap-adt-relay/`), parameterized here for the S25 on-premise
system.
