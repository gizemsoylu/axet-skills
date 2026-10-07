# aXet.code Skills

A collection of internal aXet.code skills and the supporting assets they
need. Each skill lives under `skills/<name>/SKILL.md`; anything a skill
needs beyond its own instructions (scripts, templates, examples) lives
alongside it in its own folder.

## Skills in this repo

### `abap-adt-relay`

A local relay + BTP connectivity tunnel that lets ADT-based tooling (e.g. an
MCP ABAP ADT server) reach an on-premise SAP system from your own machine,
authenticating as your **personal SAP user** through the SAP BTP
Connectivity service — no SAP-side network changes needed per developer.

- **New to this?** Follow [`SETUP.md`](./SETUP.md) step by step — it has
  exact commands and expected output for every step.
- **Using aXet.code?** Install the skill from
  [`skills/abap-adt-relay/SKILL.md`](./skills/abap-adt-relay/SKILL.md) —
  once installed, just ask your assistant things like "start the ADT
  relay" or "why is the relay returning 401", or invoke it directly with
  `%abap-adt-relay`.
- **Just want the scripts?** Copy [`agent-dir-template/`](./agent-dir-template)
  into your own project as `agent-dir/`, fill in `.cdsrc-private.json` and
  `sap_cred.env` from the provided `.example` files, then run
  `./start-relay.ps1` (or `.sh` on macOS/Linux).

## Layout

```
skills/abap-adt-relay/SKILL.md   - aXet.code skill: when/how to drive the relay
SETUP.md                         - step-by-step install + verification checklist
agent-dir-template/              - copy this folder into your project as `agent-dir/`
  package.json                   - required @sap-cloud-sdk deps
  .cdsrc-private.json.example    - BTP connectivity binding template
  sap_cred.env.example           - personal SAP user/password + destination name template
  start-relay.ps1 / .sh          - start the Node relay (background, non-blocking)
  scripts/
    abap-adt-relay.mjs           - the relay itself
    open-connectivity-tunnel.ps1 / .sh  - open the `cf ssh` tunnel to BTP
    stop-relay.ps1 / .sh         - stop both relay + tunnel, by port ownership
```

## Adding another skill to this repo

1. Create `skills/<new-skill-name>/SKILL.md` with the standard frontmatter
   (`name`, `description` as a trigger, not a summary).
2. Put any scripts/templates/examples it needs in that same folder.
3. Add a short section about it to this README.
4. Keep secrets out of git — add real credential files to `.gitignore`,
   commit only `.example` templates. Never hardcode a specific BTP app
   name, internal hostname, or system ID in a committed script — use a
   placeholder + env var override, like `scripts/open-connectivity-tunnel.*`
   does.

## Security

- `sap_cred.env` and `.cdsrc-private.json` contain real secrets (personal
  SAP password, BTP connectivity client secret). They are git-ignored by
  default — **never** remove them from `.gitignore` or commit real values.
  Only the `.example` files belong in version control.
- No internal hostnames, BTP app names, or system IDs are hardcoded in this
  repo — scripts take them as placeholders/env vars you fill in locally.
  Keep it that way if you add more skills here.
