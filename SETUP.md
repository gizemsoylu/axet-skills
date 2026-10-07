# Setup &amp; Verification Checklist — ABAP ADT Relay

Follow these steps in order on your own machine, inside your own aXet.code
session. Tick each box only after its verification command gives the
expected result — don't skip ahead if one fails.

## 0. Prerequisites

Install these before touching the relay scripts. Where to get each tool:

- [ ] **aXet.code itself** — install via your usual company portal/channel
      (not covered here; ask IT if you don't already have it).
- [ ] **Node.js** (any LTS, 18+) — install via the same company portal you
      used for aXet.code.
      Verify: `node --version`.
- [ ] **Cloud Foundry CLI (`cf`)** — install via your organization's
      standard channel. If you don't have one, ask a teammate who already
      runs this relay for a vendored copy, and point the `CF_EXE` env var
      at its full path instead of installing your own.
      Verify: `cf --version` (or `& "<path-to-cf.exe>" --version`).
- [ ] `cf login` (or `cf login --sso`) against the BTP subaccount that owns
      the connectivity instance, then `cf target -o <org> -s <space>` to the
      space that has the destination/connectivity bindings.
      Verify: `cf target` shows the right org/space.
- [ ] An existing local CAP/Node project already bound in hybrid mode to
      that subaccount's `connectivity` service (any project you use for
      local hybrid development against the same subaccount works — you do
      not need a dedicated project). It must have:
      - `node_modules/@sap-cloud-sdk/connectivity` and
        `node_modules/@sap-cloud-sdk/http-client` installed
        (`npm install @sap-cloud-sdk/connectivity @sap-cloud-sdk/http-client`
        if missing).
      - `.cdsrc-private.json` with a working
        `requires.[hybrid].connectivity.credentials` block (from
        `cf service-key` / your CAP hybrid setup docs).
- [ ] A personal SAP user + password with ADT/SICF authorization on the
      target backend. Confirm you can log into that system's GUI/Fiori with
      it *before* wiring it into the relay — the relay will faithfully
      reproduce a 401 if the credentials are wrong, so rule that out first.
- [ ] This skill installed: `%abap-adt-relay` shows up in the `%` picker
      (install via marketplace or copy `skills/abap-adt-relay/` into your
      project's `.axet-code/skills/` or your global skills folder).

## 1. Copy the template into your project

- [ ] Copy this repo's `agent-dir-template/` folder into your project as
      `agent-dir/` (any folder name is fine as long as you're consistent;
      the scripts below assume you're running them from inside it).
- [ ] Copy `.cdsrc-private.json.example` → `.cdsrc-private.json` and fill in
      the real `connectivity` credentials block (and `destinations` binding
      if your relay target needs the destination service too).
- [ ] Copy `sap_cred.env.example` → `sap_cred.env` and fill in your personal
      SAP user/password and your BTP destination name:
      ```
      SAP_USER=<your-sap-user>
      SAP_PASS=<your-sap-password>
      S4_DEST=<your-btp-destination-name>
      ```
- [ ] **Confirm both files are git-ignored** (the provided `.gitignore`
      covers this) — never commit real credentials.
      Verify: `git status` must NOT list `.cdsrc-private.json` or
      `sap_cred.env` as new/modified files once you add them.

## 2. Open the BTP connectivity tunnel

- [ ] Edit `scripts/open-connectivity-tunnel.ps1` (or `.sh`) and fill in your
      own `$AppName`/`$RemoteHost` (or `APP_NAME`/`REMOTE_HOST` on macOS/
      Linux) — or export `CF_APP_NAME`/`CONNECTIVITY_PROXY_HOST` env vars
      instead of editing the file. The script refuses to run with the
      placeholder values still in place.
- [ ] Run it:
      ```powershell
      ./scripts/open-connectivity-tunnel.ps1
      ```
- [ ] Expected output: `[tunnel] up: 127.0.0.1:20003 -> <proxy-host>:20003`
- [ ] Verify independently: `Get-NetTCPConnection -LocalPort 20003` shows
      `State = Listen`.

## 3. Start the relay

- [ ] Run from inside `agent-dir/`:
      ```powershell
      ./start-relay.ps1
      ```
- [ ] Expected output: `[relay] started in background, pid=<N> (log: .../relay.log)`
      and the command returns immediately (does not hang your shell).
- [ ] Verify independently: `Get-NetTCPConnection -LocalPort 4599` shows
      `State = Listen`.
- [ ] Check `relay.log` for the resolved destination line:
      `[relay] resolved destination "<your-dest>" -> http://..., using personal user "<your-user>"`

## 4. Verify end-to-end SAP access

- [ ] ```powershell
      Invoke-WebRequest -Uri 'http://127.0.0.1:4599/sap/bc/adt/discovery' -UseBasicParsing
      ```
- [ ] **Expected: HTTP 200** with an XML `<app:service>` body.
- [ ] If you get 502 / `ECONNREFUSED 127.0.0.1:20003` → go back to step 2,
      the tunnel died or never came up.
- [ ] If you get 401 / SAP login-failed HTML → your `sap_cred.env`
      user/password is wrong for this backend — fix it, no restart of the
      tunnel needed, just restart the relay (step 3) after editing the file.

## 5. Point your ADT/MCP client at the relay

- [ ] Configure your MCP ABAP ADT server (or any ADT HTTP client) to use
      `http://127.0.0.1:4599` as the base URL, with any dummy Basic Auth
      (the relay strips and replaces it with the personal user automatically).
- [ ] Re-run your actual ADT use case (browse an object, run a query, etc.)
      and confirm it succeeds.

## 6. Shutting down

- [ ] ```powershell
      ./scripts/stop-relay.ps1
      ```
- [ ] Expected: `[stop-relay] killed PID(s): <...>` then
      `[stop-relay] confirmed stopped.` — or
      `[stop-relay] nothing running ...` if it was already down.
- [ ] Verify: `Get-NetTCPConnection -LocalPort 4599,20003` returns nothing.

## Common pitfalls seen in practice

- **Shell "hangs" after starting the relay**: only happens with an older/
  broken `start-relay.ps1` that uses `-NoNewWindow` without redirecting
  stdin/stdout/stderr. Use the version in `agent-dir-template/` — it
  redirects all three and returns immediately.
- **A command unrelated to the relay also hangs afterwards, in the same
  session**: same root cause as above — a leftover relay process is still
  holding an inherited console pipe handle. Run `scripts/stop-relay.ps1`
  (it kills by port ownership, not by command-line scanning, so it's safe
  to run even if you're not sure what's actually running) and retry.
- **Tunnel silently drops** (e.g. after sleep/VPN hiccup): `cf ssh` doesn't
  auto-reconnect. If you suddenly get 502/ECONNREFUSED after it worked
  earlier, just re-run `open-connectivity-tunnel.ps1`.
- **Credentials file edited but relay still 401s**: the relay only reads
  `sap_cred.env` at startup. Restart it (`stop-relay.ps1` then
  `start-relay.ps1`) after any credential change.
