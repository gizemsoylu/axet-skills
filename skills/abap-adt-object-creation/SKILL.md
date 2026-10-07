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
as the verification instead of a live run, **or (d) use ABAP Unit tests
instead — see next section — which do have a documented, working "run and
get real results back" REST endpoint and are a much better live demo than
trying to coax list output out of a classic report.**

## Running ABAP Unit tests and getting real pass/fail results (this works!)

Unlike classic report execution, **ABAP Unit test execution has a proper
REST endpoint and returns real, structured pass/fail results** — this is
the best "run code live and show real output" demo available over plain
ADT REST (verified end-to-end against S25).

### Create a class with a `testclasses` include
Same `createObject` pattern as a program, but for `CLAS/OC`, and the
creation body must declare the test-classes include up front:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<class:abapClass xmlns:adtcore="http://www.sap.com/adt/core" xmlns:class="http://www.sap.com/adt/oo/classes"
  adtcore:description="..." adtcore:language="EN" adtcore:name="ZMY_CLASS" adtcore:type="CLAS/OC"
  adtcore:masterLanguage="EN" adtcore:responsible="<SAP_USER_UPPERCASE>" class:final="true" class:visibility="public">
<adtcore:packageRef adtcore:name="ZMY_PACKAGE"/>
<class:include adtcore:name="CLAS/OC" adtcore:type="CLAS/OC" class:includeType="testclasses"/>
<class:superClassRef/>
</class:abapClass>
```
`POST /sap/bc/adt/oo/classes?corrNr=<transport>`, `Content-Type: application/*`.

### Lock once, write both includes, unlock
Lock the **class main URL** (`.../oo/classes/<name>?_action=LOCK&...`), the
one `lockHandle` is valid for both includes:
```
PUT .../oo/classes/<name>/source/main?lockHandle=<handle>&corrNr=<tr>
PUT .../oo/classes/<name>/includes/testclasses?lockHandle=<handle>&corrNr=<tr>
```
**Both PUTs need `Accept: text/plain` in addition to `Content-Type:
text/plain; charset=utf-8`** — omitting `Accept` gets `406
ExceptionResourceNotAcceptable "Accepted content types: text/plain"` (this
did **not** show up when PUTting a plain program's `source/main` earlier
in this skill — class-object PUTs are stricter about `Accept`, always set
both headers to be safe for any object type).
If `.../includes/testclasses` 404s/errors on your system version, fall
back to `.../source/testclasses` — both path shapes exist across releases.
```
POST .../oo/classes/<name>?_action=UNLOCK&lockHandle=<handle>
```

### Activate (same as any object)
```xml
<adtcore:objectReference adtcore:uri="/sap/bc/adt/oo/classes/<name_lowercase>"
  adtcore:type="CLAS/OC" adtcore:name="ZMY_CLASS"/>
```

### Run the tests
```
POST /sap/bc/adt/abapunit/testruns
  Content-Type: application/*
  Accept: application/*
```
```xml
<?xml version="1.0" encoding="UTF-8"?>
<aunit:runConfiguration xmlns:aunit="http://www.sap.com/adt/aunit">
<external><coverage active="false"/></external>
<options>
<uriType value="semantic"/>
<testDeterminationStrategy sameProgram="true" assignedTests="false"/>
<testRiskLevels harmless="true" dangerous="true" critical="true"/>
<testDurations short="true" medium="true" long="true"/>
<withNavigationUri enabled="true"/>
</options>
<adtcore:objectSets xmlns:adtcore="http://www.sap.com/adt/core">
<objectSet kind="inclusive">
<adtcore:objectReferences>
<adtcore:objectReference adtcore:uri="/sap/bc/adt/oo/classes/<name_lowercase>"/>
</adtcore:objectReferences>
</objectSet>
</adtcore:objectSets>
</aunit:runConfiguration>
```
Set all `testRiskLevels`/`testDurations` flags to `"true"` so nothing gets
filtered out regardless of how the test methods are classified.

The response is a real `<aunit:runResult>` tree, one `<testClass>` per
local test class, one `<testMethod>` per test method; a method with **no
`<alerts>` child passed**, a method with an `<alerts><alert
kind="failedAssertion" ...><title>...</title><details>...Expected [X]
Actual [Y]...</details></alert></alerts>` **failed** with the exact
assertion diff. This was verified live: a class with one passing
`assert_equals` and one deliberately-wrong one produced exactly one clean
`<testMethod>` and one `<testMethod>` with a `failedAssertion` alert
showing `Expected [5] Actual [4]`.

## Creating a CDS view (DDLS) and previewing real live data (best "modern SAP" demo)

A CDS view over a standard master-data table, queried live via ADT's
**data preview** endpoint, is a stronger "real life" demo than a toy class
or a classic report: CDS views are the standard modern SAP data-modeling
building block, and this flow returns **actual rows from the system**
(verified: queried `T005T` country-name master data and got real country
names/keys back, e.g. `DE`/`Germany`, `TR`/`Türkiye`, `US`/`USA`).

### 1. Create
`creationPath` for `DDLS/DF`:
`POST /sap/bc/adt/ddic/ddl/sources?corrNr=<transport>`, `Content-Type: application/*`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ddl:ddlSource xmlns:ddl="http://www.sap.com/adt/ddic/ddlsources" xmlns:adtcore="http://www.sap.com/adt/core"
  adtcore:name="ZMY_CDS_VIEW" adtcore:type="DDLS/DF" adtcore:language="EN" adtcore:masterLanguage="EN"
  adtcore:responsible="<SAP_USER_UPPERCASE>" adtcore:description="...">
<adtcore:packageRef adtcore:name="ZMY_PACKAGE"/>
</ddl:ddlSource>
```

### 2. Lock, write DDL source, unlock
Same lock/unlock pattern as classes/programs
(`.../ddic/ddl/sources/<name_lowercase>?_action=LOCK&accessMode=MODIFY`,
`X-sap-adt-sessiontype: stateful` on every call). Write the DDL text to
`.../ddic/ddl/sources/<name_lowercase>/source/main?lockHandle=<handle>&corrNr=<tr>`
with `Content-Type: text/plain; charset=utf-8` **and** `Accept:
text/plain` (same 406 trap as classes — always set both). A minimal,
safe-everywhere DDL body (standard table, no custom dependencies, no
sensitive data):
```abap
@AbapCatalog.sqlViewName: 'ZMYCDSVIEWSQL'
@AbapCatalog.compiler.compareFilter: true
@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: 'Demo CDS view'
define view ZMY_CDS_VIEW as select from t005t
{
  key land1 as CountryKey,
  key spras as Language,
  landx     as CountryName
}
where spras = 'E'
```
`AbapCatalog.sqlViewName` is limited to 16 characters (classic SQL-view
naming rule) — keep it short regardless of how long the CDS entity name
itself is.

### 3. Activate
Same `/sap/bc/adt/activation` call as any object, with
`adtcore:type="DDLS/DF"`. A `200` with `checkExecuted="true"
activationExecuted="true"` is success even if `generationExecuted="false"`
— that third flag just means no separate classic SQL view database object
was (re)generated, which is normal/harmless on HANA-based systems where
CDS views don't need one; data preview still works regardless.

### 4. Query it live — the actual "run and see real output" step
```
POST /sap/bc/adt/datapreview/ddic?rowNumber=20&ddicEntityName=<CDS_view_name>
  Content-Type: text/plain
  Accept: application/xml, application/vnd.sap.adt.datapreview.table.v1+xml
  X-CSRF-Token: <csrf>
  X-sap-adt-sessiontype: stateful
  body: (empty string is fine for a plain preview of the view's own definition)
```
`ddicEntityName` is the CDS view name, URL-encoded (no leading slash
needed for a `Z*`/`Y*` custom view — the `%2FDMO%2FTRAVEL`-style encoding
seen in some examples is specific to namespaced `/DMO/...` demo content,
not a general requirement).

Response is `<dataPreview:tableData>` with one `<dataPreview:columns>`
block per column, each holding `<dataPreview:metadata>` (name/type/length)
and a `<dataPreview:dataSet>` of `<dataPreview:data>` values — i.e. a
column-oriented table dump of **real rows actually in the system**, not a
dry-run or canned response. There's also a sibling
`/sap/bc/adt/datapreview/freestyle?rowNumber=<n>` endpoint for arbitrary
`SELECT ...` text bodies instead of a named DDIC entity, for ad-hoc
queries beyond a single CDS view/table.

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
