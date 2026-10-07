---
name: abap-adt-object-creation
description: Use when the user wants to create or modify ABAP repository objects (packages, transport requests, programs/reports, classes, etc.) on an SAP system via the raw ADT REST API — e.g. through the abap-adt-relay — without a full-featured ADT/MCP client library doing session management for them. Also use when writes/locks via the relay fail with HTTP 423 "invalid lock handle" or 400 "Check of condition failed" during activation.
---

# ABAP ADT Object Creation (raw REST API, stateful sessions)

## When to use this skill

Use this skill whenever the user wants to create/edit ABAP objects (a
package, a transport request, a program/report, a class, etc.) by talking
directly to the ADT REST API over HTTP — typically through the
`abap-adt-relay` skill's `http://127.0.0.1:4599` endpoint — instead of a
proper ADT client library. Also use it to diagnose:
- `HTTP 423` + `ExceptionResourceInvalidLockHandle` ("Resource ... is not
  locked (invalid lock handle: ...)") even though the preceding LOCK call
  returned `200` with a `LOCK_HANDLE`.
- `HTTP 400` + `ExceptionInvalidData` ("Check of condition failed") during
  `/sap/bc/adt/activation`.
- `HTTP 400` + "Package X may not be assigned to software component LOCAL"
  (message TR462) when creating a package.

## The critical fix: stateful session header

**Every single ADT request that is part of a stateful edit session (CSRF
fetch, LOCK, PUT source, UNLOCK, activate) must carry:**
```
X-sap-adt-sessiontype: stateful
```
Without this header, the CSRF-token GET, LOCK and PUT calls all return
`200 OK` individually and *look* fine — the LOCK call happily returns a
`LOCK_HANDLE`, cookies (`SAP_SESSIONID_...`, `sap-usercontext`) are present
and correctly reused across calls — but the very next write against that
lock handle fails with:
```
423 ExceptionResourceInvalidLockHandle
Resource INCLUDE <NAME> is not locked (invalid lock handle: <handle>)
```
This is **not** a cookie/session-continuity bug and not a lock-handle
parsing bug (verified: raw `Set-Cookie` headers, cookie reuse via a single
`-WebSession`/`WebRequestSession`, and the exact `LOCK_HANDLE` string were
all confirmed correct). The backend was simply treating every request as a
*new stateless* ADT session because the stateful-session opt-in header was
missing, so the lock lived in a session the next stateless call never saw.
Adding `X-sap-adt-sessiontype: stateful` to the CSRF GET and to every
subsequent call in that edit session fixes it immediately — no other
change needed.

## End-to-end working flow (PowerShell / Invoke-WebRequest over the relay)

All calls below go through the relay (`http://127.0.0.1:4599`), which
already handles Basic Auth to the backend — see `abap-adt-relay` skill.
Use a single `-SessionVariable`/`-WebSession` for the whole flow so cookies
are preserved; `Export-Clixml`/`Import-Clixml` **cannot** round-trip a
`WebRequestSession` across PowerShell processes (type mismatch on
reimport), so do the entire flow inside **one** script invocation.

### 1. CSRF token + stateful session
```powershell
$resp1 = Invoke-WebRequest -Uri "$base/sap/bc/adt/discovery" -Method GET `
  -Headers @{ 'X-CSRF-Token' = 'Fetch'; 'X-sap-adt-sessiontype' = 'stateful' } `
  -SessionVariable sess -UseBasicParsing
$csrf = $resp1.Headers['x-csrf-token']
```

### 2. Create a package (if needed)
`POST /sap/bc/adt/packages`, `Content-Type: application/*`, `X-CSRF-Token`.
The element order inside `<pak:package>` is **strict** — the backend
rejects out-of-order/missing elements one at a time with a specific
"System expected the element '{...}X'" error, so just include all of them
in this exact order:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<pak:package xmlns:pak="http://www.sap.com/adt/packages" xmlns:adtcore="http://www.sap.com/adt/core"
  adtcore:name="ZMY_PACKAGE" adtcore:type="DEVC/K" adtcore:description="..."
  adtcore:responsible="<SAP_USER_UPPERCASE>" adtcore:masterLanguage="EN" adtcore:language="EN">
<pak:attributes pak:packageType="development"/>
<pak:superPackage/>
<pak:applicationComponent/>
<pak:transport>
<pak:softwareComponent pak:name="LOCAL"/>
<pak:transportLayer/>
</pak:transport>
<pak:translation/>
<pak:useAccesses/>
<pak:packageInterfaces/>
<pak:subPackages/>
</pak:package>
```
- `pak:transportLayer` must be present even when empty (self-closing tag) —
  omitting the element entirely (not just leaving it valueless) throws
  "System expected the element '{...}transportLayer'".
- **Software component `LOCAL` is only allowed for packages whose name
  starts with `TEST` or `$`** (backend message TR462: "Package X may not be
  assigned to software component LOCAL ... You can only assign packages
  that start with TEST or $ to the software component LOCAL"). For a quick
  throwaway/demo package, name it `TEST_<something>` and keep
  `softwareComponent=LOCAL` — no need to look up the system's real custom
  software component. For a package meant to actually ship, query
  `GET /sap/bc/adt/packages/valuehelps/softwarecomponents` and
  `GET /sap/bc/adt/packages/valuehelps/transportlayers` first and use a
  real entry (in this project's S25 those two valuehelp GETs threw a
  non-HTTP PowerShell exception — status `-1`, no `Response` object at all —
  worth re-investigating with `-Verbose`/raw socket capture if a real SWC
  is ever needed; it did not block using the `TEST_*` + `LOCAL` shortcut).

### 3. Create a transport request
`POST /sap/bc/adt/cts/transports`, with:
```
Content-Type: application/vnd.sap.as+xml; charset=UTF-8; dataname=com.sap.adt.CreateCorrectionRequest
Accept: text/plain
X-CSRF-Token: <csrf>
```
Body (the generic "asx abap" wrapper SAP uses for simple flat RFC-style
structures):
```xml
<?xml version="1.0" encoding="UTF-8"?><asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0">
    <asx:values>
      <DATA>
<DEVCLASS>ZMY_PACKAGE</DEVCLASS>
<REQUEST_TEXT>Description of the change</REQUEST_TEXT>
<REF>/sap/bc/adt/packages/zmy_package</REF>
<OPERATION>I</OPERATION>
      </DATA>
    </asx:values>
  </asx:abap>
```
The response body is a plain-text path like
`/com.sap.cts/object_record/S25K906222` — the transport number is
everything after the last `/`.

### 4. Create the object (e.g. a program/report)
`POST /sap/bc/adt/programs/programs?corrNr=<transport>`,
`Content-Type: application/*`, `X-CSRF-Token`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<program:abapProgram xmlns:program="http://www.sap.com/adt/programs/programs" xmlns:adtcore="http://www.sap.com/adt/core"
  adtcore:name="ZMY_REPORT" adtcore:type="PROG/P" adtcore:description="..."
  adtcore:masterLanguage="EN" adtcore:responsible="<SAP_USER_UPPERCASE>">
<adtcore:packageRef adtcore:name="ZMY_PACKAGE"/>
</program:abapProgram>
```
Other object types follow the same `createObject`-style pattern — see
`CreatableTypes` map in
[`marcellourbani/abap-adt-api`](https://github.com/marcellourbani/abap-adt-api)
`src/api/objectcreator.ts` for the `creationPath`/`rootName`/`nameSpace`/
`typeId` of classes, interfaces, function groups, etc.

### 5. Lock, write source, unlock
```
POST  .../programs/programs/<name_lowercase>?_action=LOCK&accessMode=MODIFY
  Accept: application/*,application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.lock.result
  X-sap-adt-sessiontype: stateful   <-- required, see above
```
Parse `LOCK_HANDLE` out of the `<asx:abap><asx:values><DATA><LOCK_HANDLE>`
response. Locking either the main object URL or the
`.../source/main` URL both return a handle; **as long as the stateful
header is set**, either works for the subsequent write.
```
PUT   .../programs/programs/<name_lowercase>/source/main?lockHandle=<handle>&corrNr=<transport>
  Content-Type: text/plain; charset=utf-8
  X-sap-adt-sessiontype: stateful
  body: raw ABAP source text
```
```
POST  .../programs/programs/<name_lowercase>?_action=UNLOCK&lockHandle=<handle>
  X-sap-adt-sessiontype: stateful
```

### 6. Activate
```
POST /sap/bc/adt/activation?method=activate&preauditRequested=true
  Content-Type: application/xml
  Accept: application/xml
  X-sap-adt-sessiontype: stateful
```
```xml
<?xml version="1.0" encoding="UTF-8"?>
<adtcore:objectReferences xmlns:adtcore="http://www.sap.com/adt/core">
<adtcore:objectReference adtcore:uri="/sap/bc/adt/programs/programs/zmy_report"
  adtcore:type="PROG/P" adtcore:name="ZMY_REPORT"/>
</adtcore:objectReferences>
```
- **Do not include `adtcore:parentUri=""`** (empty string) on the
  `objectReference` — it causes `400 ExceptionInvalidData "Check of
  condition failed"`. Either omit the attribute entirely (works for a
  simple standalone program, as verified) or set it to the real
  containing-package URI if the backend demands it for other object types.
- A `200` response with
  `<chkl:messages ... checkExecuted="true" activationExecuted="true" generationExecuted="true"/>`
  and no `<chkl:messageList>` entries means a clean activation (no
  syntax/activation errors).

### 7. Verify
```
GET .../programs/programs/<name_lowercase>/source/main
  Accept: text/plain
```
(A GET without `Accept: text/plain` can get a `406 Not Acceptable` from
this resource — always set it explicitly when reading source back.)

## There is no REST endpoint to "run" a classic report and get its WRITE output

Do **not** spend time trying to execute a classic `REPORT ... WRITE:`
program through the ADT REST API and capture its list output — this was
tried exhaustively and confirmed to be a hard platform limitation, not a
missing header/format issue:
- `POST .../programs/programs/<name>?method=run` → `400
  ExceptionInvalidData "System expected the element '{...}abapProgram'"`
  (the resource interprets POST as an update, requiring the full
  `program:abapProgram` body — there is no `run` action on it).
- `POST .../programs/programs/<name>?_action=RUN` → `405 Method Not
  Allowed`.
- `GET` with either of the above query strings just returns the normal
  object metadata (query params are silently ignored on GET).
- Guessed resources like `/sap/bc/adt/debugger/execution/<name>` or
  `.../programs/programs/<name>/console` → `404 Not Found`.
- Classic program list output (`WRITE`) being shown in the ADT "ABAP
  Console" view when pressing **F9** in Eclipse is a **frontend-only**
  Eclipse-IDE feature (NetWeaver 7.52+): Eclipse runs the program through
  an interactive SAP GUI-protocol session under the hood and renders the
  classic list in the console view — there is no corresponding "give me
  the list output as text over REST" resource.
- `IF_OO_ADT_CLASSRUN` console classes (the `out->write()` style, meant to
  be run with F9 as a "console application") are also an Eclipse
  IDE-integrated feature; no public ADT REST client library (including
  `marcellourbani/abap-adt-api`, which has no `run`/`console`/`classrun`
  module at all — checked its full `src/api/` file list) implements or
  documents a REST call for it.

**Bottom line:** if a user wants to see program output from an ADT-created
report, the only real options are (a) open it in SAP GUI / Eclipse ADT
and run it there (F8/F9), (b) submit it as a background job via RFC
(`BAPI_XMI_LOGON` + `JOB_OPEN`/`JOB_SUBMIT`/`JOB_CLOSE` or similar) and
read the spool — which requires an RFC-capable channel, not the plain
HTTP relay this skill/the `abap-adt-relay` skill provides — or (c) if the
goal is just to prove the object was created/activated correctly, use the
read-back-source + activation-success-message pattern in step 6/7 above
as the verification instead of a live run.

## Credential handling

Same rule as `abap-adt-relay`: load `sap_cred.env` into env vars silently
(`Set-Item -Path env:X -Value ...` in a loop, never `Write-Host`/print),
and use `$env:SAP_USER.ToUpper()` as the `adtcore:responsible` attribute
value without ever echoing it.

## Source

Derived empirically against the S25 sandbox system in this project
(hostname contains `sbx`, confirmed low-risk for experimentation) by
cross-referencing the request/response shapes used in
[`marcellourbani/abap-adt-api`](https://github.com/marcellourbani/abap-adt-api)
(TypeScript ADT client library) and discovering the missing
`X-sap-adt-sessiontype: stateful` header through trial and error, since
that header is not obviously documented and the library's own HTTP layer
sets it internally for every call once a session goes stateful.
