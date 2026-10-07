// Generic local HTTP relay so a plain ADT-based MCP server (e.g. mcp-abap-adt) can
// reach an on-premise ABAP system through the SAP Cloud SDK + BTP connectivity proxy,
// authenticating as a personal SAP user instead of a destination's own service user
// (useful when that service user has no ADT/SICF authorization).
//
// This script is project-agnostic: every project-specific value comes from env vars
// (see SKILL.md for how the skill collects and passes them). It borrows an existing
// CAP project's node_modules (@sap-cloud-sdk/connectivity + http-client) and its
// .cdsrc-private.json hybrid `connectivity` binding -- it does not install its own
// copy or maintain its own BTP binding.
//
// Required env vars:
//   AGENT_DIR          Absolute path to a local CAP project that already has
//                       @sap-cloud-sdk/connectivity + http-client installed and a
//                       working requires.[hybrid].connectivity binding in its
//                       .cdsrc-private.json (any project set up for local hybrid dev
//                       against the same BTP subaccount/connectivity instance works).
//   S4_DEST            BTP destination name for the on-premise ABAP system.
//   PERSONAL_SAP_USER / PERSONAL_SAP_PASSWORD
//                       Personal SAP user to authenticate ADT calls as (overrides the
//                       destination's own configured user/password).
// Optional env vars:
//   RELAY_PORT          Local port to listen on (default 4599).
//   CF_EXE               Path to cf.exe, needed only if AGENT_DIR's .cdsrc-private.json
//                        has a `destinations` binding (reads a live service key via cf).
//
// Prereq: a cf ssh tunnel to AGENT_DIR's connectivity proxy must already be open on
// the port referenced by its .cdsrc-private.json connectivity credentials
// (onpremise_proxy_host/port) -- see SKILL.md, step 1.

import http from 'node:http';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

function requireEnv(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`[relay] Missing required env var ${name}.`);
    process.exit(1);
  }
  return v;
}

const AGENT_DIR = requireEnv('AGENT_DIR');
const DEST_NAME = requireEnv('S4_DEST');
const PERSONAL_USER = requireEnv('PERSONAL_SAP_USER');
const PERSONAL_PASSWORD = requireEnv('PERSONAL_SAP_PASSWORD');
const RELAY_PORT = Number(process.env.RELAY_PORT || 4599);

const require = createRequire(path.join(AGENT_DIR, 'package.json'));
const { executeHttpRequest } = require('@sap-cloud-sdk/http-client');
const { getDestination } = require('@sap-cloud-sdk/connectivity');

// Build VCAP_SERVICES from AGENT_DIR's .cdsrc-private.json hybrid connectivity +
// (optional) destinations bindings, same shape @sap-cloud-sdk/connectivity expects.
const cdsrc = JSON.parse(fs.readFileSync(path.join(AGENT_DIR, '.cdsrc-private.json'), 'utf8'));
const hybrid = cdsrc.requires['[hybrid]'];
if (!hybrid?.connectivity?.credentials) {
  console.error(`[relay] ${AGENT_DIR}\\.cdsrc-private.json has no requires.[hybrid].connectivity binding.`);
  process.exit(1);
}

const vcap = { connectivity: [{ label: 'connectivity', name: 'connectivity', credentials: hybrid.connectivity.credentials }] };

if (hybrid.destinations?.binding) {
  const { execSync } = await import('node:child_process');
  const CF = process.env.CF_EXE || 'cf';
  const raw = execSync(`"${CF}" service-key "${hybrid.destinations.binding.instance}" "${hybrid.destinations.binding.key}"`, { encoding: 'utf8' });
  const m = raw.match(/\{[\s\S]*\}/);
  const destCreds = JSON.parse(m[0]).credentials;
  vcap.destination = [{ label: 'destination', name: 'destinations', credentials: destCreds }];
}

process.env.VCAP_SERVICES = JSON.stringify(vcap);
process.env.VCAP_APPLICATION = process.env.VCAP_APPLICATION || '{}';

// Resolve the destination once (gets URL / proxyType / cloud connector routing from BTP),
// then override the credentials with the personal SAP user.
const baseDestination = await getDestination({ destinationName: DEST_NAME });
if (!baseDestination) {
  console.error(`[relay] Could not resolve destination "${DEST_NAME}".`);
  process.exit(1);
}
const destination = { ...baseDestination, username: PERSONAL_USER, password: PERSONAL_PASSWORD };
console.log(`[relay] resolved destination "${DEST_NAME}" -> ${destination.url}, using personal user "${PERSONAL_USER}"`);

const server = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks);

  try {
    const headers = { ...req.headers };
    delete headers.host;
    delete headers['content-length'];
    // The MCP server sends its own Basic Auth header (from dummy SAP_USERNAME/PASSWORD);
    // strip it so the SDK applies the personal-user BasicAuthentication set above instead.
    delete headers.authorization;

    const response = await executeHttpRequest(
      destination,
      {
        method: req.method.toLowerCase(),
        url: req.url,
        headers,
        data: body.length ? body : undefined,
        responseType: 'text',
      },
      { fetchCsrfToken: false }
    );

    // response.headers reflects the upstream (possibly compressed) byte length; axios already
    // decompressed response.data, so forwarding the original content-length/encoding truncates
    // the body at the client. Strip both and let Node compute the correct length.
    const outHeaders = { ...response.headers };
    delete outHeaders['content-length'];
    delete outHeaders['content-encoding'];
    delete outHeaders['transfer-encoding'];
    res.writeHead(response.status, outHeaders);
    res.end(response.data);
  } catch (err) {
    const status = err?.response?.status || 502;
    const data = err?.response?.data || String(err?.message || err);
    console.error(`[relay] ${req.method} ${req.url} -> ${status}`, data?.toString?.().slice(0, 300));
    res.writeHead(status, { 'content-type': 'text/plain' });
    res.end(typeof data === 'string' ? data : JSON.stringify(data));
  }
});

server.listen(RELAY_PORT, '127.0.0.1', () => {
  console.log(`[relay] listening on http://127.0.0.1:${RELAY_PORT} -> destination "${DEST_NAME}"`);
});
