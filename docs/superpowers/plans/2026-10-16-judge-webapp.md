# Judge Web App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A web page (served by IRIS at `/medic/` and as a static GitHub Pages site) where judges pick or build a failed message, watch it flow through the fast tier and the AI Hub agent, act as the person in the loop, and run batches of 5.

**Architecture:** IRIS gains a structured per-decision trace, an audit table, a precedent store on IRIS Vector Search with a `SearchPrecedents` agent tool, and a `%CSP.REST` API. One static front end (plain HTML/CSS/JS, no build step) talks to that API when it is reachable ("Live"), and otherwise replays a recorded JSON bundle plus browser-side mock models ("Replay" / "Mock").

**Tech Stack:** ObjectScript (Interoperability, `%CSP.REST`, `%Library.Vector`, `%SQL.Index.HNSW`, `%UnitTest`), vanilla JS ES modules tested with `node --test` (Node 24), Python 3.11+ via `uv` (stdlib only), Docker Compose, GitHub Actions for Pages.

**Spec:** `docs/superpowers/specs/2026-10-16-judge-webapp-design.md`. Visual reference: `.superpowers/brainstorm/553-1792172282/content/hub-v4.html` (git-ignored; Task 6 copies it to `web/reference/hub-v4.html`).

## Global Constraints

- Plain HTML/CSS/JS, no framework, no bundler, no npm dependencies; the same `web/` folder is served by IRIS and by GitHub Pages unchanged.
- Keys stay server-side (`.env`); nothing under `web/` may contain or request a key.
- Every number on the page comes from a run (live, replayed recording, or mock run in the browser); no hard-coded figures.
- Honesty labels, verbatim: screen top bar shows `Live`, `Replay of a real run`, or `Mock`; simulated downstream effects end with ` (simulated)`; "Saved as a precedent" appears only after the store call returned success.
- The default community image (no `%AI`) must still build and serve the page; AI Hub classes stay in `src-aihub/`.
- Layout must not overflow at 1280 px wide and must stack into one column below 900 px.
- Synthetic data only; recorded scenarios use cases whose patient names are plain ASCII.
- The GitHub Pages workflow is manual (`workflow_dispatch`) so nothing publishes before 26 Oct 2026.
- IRIS unit tests run with `set ^UnitTestRoot="/tmp"` then `do ##class(%UnitTest.Manager).DebugRunTestCase("","<Class>","","")`; pass = output ends with `All PASSED`.
- Rebuilds: `docker compose up -d --build`; readiness: `docker exec interop-medic iris session IRIS -U USER "##class(Medic.Setup).Doctor()"` shows no `[FAIL]`.

## Review Focus

1. **The real agent is slow or fails mid-run (≈19 s per decision, Gemini rate limits).** A batch must keep showing progress per case, and an agent failure must appear as an "Agent unavailable" step, never as a real decision. Pinned in Task 1 (unavailable step) and Task 6 (progress state).
2. **Malformed "Build your own" input** (empty message, non-JSON FHIR, 200 KB paste). The API must answer 400 with a readable message and the page must show it. Pinned in Task 4 and Task 7.
3. **Acting twice** (approve after approve, override an auto-applied decision, reroute without target). The API must answer 409/400 and change nothing. Pinned in Task 2 and Task 4.
4. **Non-ASCII text** (accented names) must round-trip through the API as UTF-8 and render correctly. Pinned in Task 4.
5. **No API reachable** (opened from GitHub Pages or a file) must switch to Replay/Mock within 2 s without console errors. Pinned in Task 5.

---

### Task 1: Structured trace on every decision

Also commits the uncommitted build-154 fixes already in the working tree (`src-aihub/Medic/AIHub/ToolTrace.cls` signature, `docker-compose.yml` entrypoint, `.gitignore`).

**Files:**
- Modify: `src/Medic/Msg/Decision.cls` (add `TraceJSON`, `AddStep`, `Steps`; include `TraceJSON` in `CopyFrom`)
- Modify: `src/Medic/Operation/FastTier.cls`, `src/Medic/Operation/Agent.cls`, `src/Medic/Process/Triage.cls` (BPL code block), `src/Medic/Provider/AgentMock.cls`, `src/Medic/Provider/AIHubAgent.cls`, `src-aihub/Medic/AIHub/ToolTrace.cls` (record a result summary)
- Modify: `src/Medic/Eval/Runner.cls` (`AsJSON` adds `"trace"`)
- Test: `src/Medic/Test/Trace.cls`

**Interfaces:**
- Produces: `Medic.Msg.Decision.TraceJSON As %String(MAXLEN="")` holding a JSON array of steps `{"stage","status","value","detail","ms"}`; `status` ∈ `ok|warn|bad|hum`.
- Produces: `Method AddStep(pStage As %String, pStatus As %String, pValue As %String, pDetail As %String = "", pMs As %Integer = 0)` and `Method Steps() As %DynamicArray`.
- Produces: `Medic.AIHub.ToolTrace.Calls` entries gain `"summary"` (first 160 chars of the result JSON).

Step stages, in order: fast tier stage named after the provider short name (`Jev`, `Laya`, `Mock`) with value `"<action> <confidence 2dp>"`; `Gate` with value `trusted` or `to agent` and a detail naming the reason (`confidence 0.42 < 0.85`, `severity 0.95 ≥ 0.6`, `reroute needs a target`); one step per agent tool call (stage = tool name, value = short result); `Agent` with value `"<action> <confidence>"`, or value `unavailable` and status `bad` when the provider fell back; `Policy` with value `auto-apply` or `held for a person`.

- [ ] **Step 1: Write the failing test** `Medic.Test.Trace` with `TestAddStepShape` (two `AddStep` calls → `Steps().%Size()=2`, first step's `stage`, `status`, `value` equal the inputs), `TestCopyFromKeepsTrace` (`CopyFrom` copies `TraceJSON`), `TestAgentMockAddsSteps` (AgentMock deciding an `unknown_receiver` case adds a `ClosestRoute` step and an `Agent` step whose value starts with `reroute`), `TestUnavailableStep` (`Medic.Provider.AIHubAgent.Decide` on the community image yields a last step with stage `Agent`, value `unavailable`, status `bad`; `quit` early when `Medic.AIHub.TriageAgent` exists).
- [ ] **Step 2: Load and run it; expect failures** (`AddStep` undefined).
- [ ] **Step 3: Implement** `AddStep`/`Steps` on `Decision`, then emit steps from FastTier, Agent (Gate step before deciding; the fast tier's steps are copied first so the final decision carries the whole trace), AgentMock (a step for each `Medic.Tools` call it makes), AIHubAgent (one step per `ToolTrace.Calls` entry, then the `Agent` step; the fail-safe path adds the `unavailable` step), and the Triage BPL code block (`Policy` step after `CanAutoApply`). `Runner.AsJSON` adds `"trace": (d.Steps())`.
- [ ] **Step 4: Run** `Medic.Test.Trace`, `Medic.Test.SystemOne`, `Medic.Test.AIHubAgent` → `All PASSED` each; `uv run python eval/run.py --limit 5 --tag trace-check` → every line in `data/results/trace-check/results.jsonl` has `final.trace` with ≥3 steps ending in `Policy`.
- [ ] **Step 5: Commit** `feat: structured decision trace; build-154 fixes`.

### Task 2: Audit trail, person actions and the precedent store

**Files:**
- Create: `src/Medic/Data/Audit.cls`, `src/Medic/Data/Precedent.cls`, `src/Medic/Data/Embed.cls`, `src/Medic/Actions.cls`
- Test: `src/Medic/Test/Actions.cls`

**Interfaces:**
- Consumes: `Medic.Msg.Decision.AddStep`, `Steps()` (Task 1).
- Produces: `Medic.Data.Audit` (%Persistent): `DecisionId As %Integer`, `CaseId`, `At As %TimeStamp`, `Actor`, `Event`, `Detail(MAXLEN=1000)`; `ClassMethod Log(pDecisionId, pCaseId, pActor, pEvent, pDetail = "") As %Status`; `ClassMethod ForDecision(pDecisionId) As %DynamicArray` (oldest first, items `{"at","actor","event","detail"}`).
- Produces: `Medic.Data.Embed.Text(pText As %String) As %String` returning a 256-dimension comma-separated vector for `TO_VECTOR(..., DOUBLE)`: lower-case, split on non-alphanumerics, drop digit-only tokens, hash each token and each adjacent-token bigram with `$zcrc(token,7)#256`, accumulate counts, L2-normalise. Deterministic and needs no key, so mock mode works.
- Produces: `Medic.Data.Precedent` (%Persistent): `CaseId`, `ErrorText(MAXLEN=4000)`, `Summary(MAXLEN=1000)`, `Action`, `RerouteTarget`, `DecidedBy`, `At As %TimeStamp`, `Embedding As %Library.Vector(DATATYPE="DOUBLE", LEN=256)`, `Index EmbeddingIdx On (Embedding) As %SQL.Index.HNSW(Distance="Cosine")`; `ClassMethod Store(pDecision As Medic.Msg.Decision, pErrorText, pSummary, pDecidedBy) As %Status`; `ClassMethod Search(pText As %String, pTop As %Integer = 3) As %DynamicArray` (items `{"caseId","action","rerouteTarget","decidedBy","similarity","summary"}`, ordered by `VECTOR_COSINE` descending).
- Produces: `Medic.Actions.Approve(pDecisionId As %Integer, pActor As %String = "demo-user") As %DynamicObject`, `Medic.Actions.Override(pDecisionId As %Integer, pAction As %String, pRerouteTarget As %String = "", pReason As %String = "", pActor As %String = "demo-user") As %DynamicObject`, each returning `{"ok":1,"decision":{...},"trace":[...],"audit":[...],"precedent":0|1}` or throwing `%Exception.StatusException` whose text contains `already decided by a person`, `reroute needs a target`, or `unknown action`; and `Medic.Actions.DecisionJSON(pDecision As Medic.Msg.Decision) As %DynamicObject` (`id, caseId, action, confidence, severity, rationale, proposedFix, rerouteTarget, decidedBy, provider, autoApplied, latencyMs, costUSD, trace, audit`), reused by Task 4.

Rules: approve or override only when `Decision.AutoApplied = 0` and no `hum` step exists yet; override to `reroute` requires a target present in the `MedicRouting` lookup; approve logs `You · approved <action>` plus a production event whose detail ends ` (simulated)` (escalate → `on-call ward paged (simulated)`, others → `<action> applied (simulated)`); override logs `You · overrode → <action>` plus `Eval · correction recorded`; both store a precedent with the final action and set `precedent:1` only when `Store` returned OK. Persist the new `hum` step and any overridden action on the Decision (`%Save`).

- [ ] **Step 1: Write the failing test** `Medic.Test.Actions`: `TestEmbedIsDeterministicAndUnit` (same text → same vector; L2 norm within 0.001 of 1), `TestApproveEscalation` (an unapplied escalate Decision → `Approve` → last trace step status `hum`, audit has 2 rows with one detail ending `(simulated)`, `precedent=1`), `TestApproveTwiceRejected` (second `Approve` throws with text containing `already decided`), `TestAutoAppliedRejected`, `TestOverrideRerouteNeedsTarget` (no target → throws `reroute needs a target`; with `Medic.To.EPR` → action `reroute`, target set), `TestSearchFindsApproved` (after approving a case with error text `No routing rule matched MSH:5 'EPRR'`, `Search("No routing rule matched MSH:5 'EPR1'")` returns that case first with similarity > 0.5).
- [ ] **Step 2: Run; expect failures.**
- [ ] **Step 3: Implement** the four classes per the Interfaces block.
- [ ] **Step 4: Run** `Medic.Test.Actions` → `All PASSED`; also build on the community image (`IRIS_IMAGE=intersystemsdc/iris-community:2026.2-zpm docker compose build`) → succeeds, so the HNSW index compiles there too.
- [ ] **Step 5: Commit** `feat: audit trail, approve/override actions, vector precedent store`.

### Task 3: `SearchPrecedents` tool for both agents

**Files:**
- Modify: `src/Medic/Tools.cls` (add `SearchPrecedents`), `src/Medic/Provider/AgentMock.cls`, `src-aihub/Medic/AIHub/Tools.cls`, `src-aihub/Medic/AIHub/ReadOnlyPolicy.cls` (`ALLOWED` adds `SearchPrecedents`), `src-aihub/Medic/AIHub/TriageAgent.cls` (instructions: call `SearchPrecedents` first; cite `precedent <caseId>` in the rationale when relying on one; precedents never override the safety rules)
- Test: add `TestMockUsesPrecedent` to `src/Medic/Test/Actions.cls`

**Interfaces:**
- Consumes: `Medic.Data.Precedent.Search` (Task 2).
- Produces: `Medic.Tools.SearchPrecedents(pErrorText As %String) As %String` = `Medic.Data.Precedent.Search(pErrorText, 3).%ToJSON()`.

AgentMock: when the top precedent has similarity ≥ 0.8, add a `SearchPrecedents` step (value `precedent <caseId>`) and append `Precedent <caseId>: <action>.` to the rationale; its decision logic is otherwise unchanged.

- [ ] **Step 1: Write the failing test** `TestMockUsesPrecedent`: approve one `unknown_receiver` decision, then AgentMock on a second `unknown_receiver` case has a `SearchPrecedents` step and a rationale containing `Precedent`.
- [ ] **Step 2: Run; expect failure.**
- [ ] **Step 3: Implement** the tool, the AI Hub wrapper and policy entry, the instruction lines, and the mock behaviour.
- [ ] **Step 4: Run** `Medic.Test.Actions` → `All PASSED`; on build 154 with the Gemini agent, approve one `unknown_receiver` decision, then `Medic.Provider.AIHubAgent.Decide` on another → its trace contains a `SearchPrecedents` step.
- [ ] **Step 5: Commit** `feat: SearchPrecedents tool for the AI Hub agent and the mock`.

### Task 4: REST API and IRIS web applications

**Files:**
- Create: `src/Medic/API/Dispatch.cls` (`%CSP.REST`), `src/Medic/API/Scenarios.cls`, `src/Medic/API/Models.cls`, `web/index.html` (placeholder, replaced in Task 6)
- Modify: `src/Medic/Setup.cls` (create web apps; `Doctor` checks them), `Dockerfile` (copy `web/`)
- Test: `tests/test_api.py` (Python `unittest` + `urllib`; skips with a clear message when `http://localhost:52773/medic/api/health` is unreachable)

**Interfaces:**
- Consumes: `Medic.Actions.Approve/Override/DecisionJSON` and `Medic.Data.Audit.ForDecision` (Task 2), `Decision.Steps()` (Task 1), `Medic.Msg.FailedMessage.FromCase` and the `Medic.Eval` business service (existing) to run a case synchronously through `Medic.Triage`.
- Produces (JSON, `Content-Type: application/json; charset=utf-8`, errors as `{"error":"<text>"}`):
  - `GET /medic/api/health` → `{"mode":"live","aihub":bool,"build":"<short $zversion>"}`
  - `GET /medic/api/scenarios` → `[{"id","label","case":{...}}]`, one per corruption type; labels `endpoint_timeout`→"Endpoint timeout", `outage_critical_result`→"Critical result", `unknown_receiver`→"Misspelt receiver", `patient_mismatch`→"Wrong patient", others the type name in sentence case; each picks the first case whose `raw_message` is ASCII; the four named ones come first.
  - `GET /medic/api/cases/random?n=5` → `[{"case":{...},"expected":{...}}]`, `n` clamped to 1–10.
  - `POST /medic/api/triage` body `{"case":{...}}` → `Medic.Actions.DecisionJSON`. 400 when `raw_message` is empty, longer than 100 000 characters, or `format` is `fhir` and the message is not valid JSON.
  - `POST /medic/api/decisions/:id/approve` body `{"actor"?}`; `POST /medic/api/decisions/:id/override` body `{"action","rerouteTarget"?,"reason"?}` → Task 2 result; 409 for "already decided", 400 for validation errors.
  - `GET /medic/api/models` → `{"fast":"Jev|Laya|Mock","agent":"Gemini|Mock","available":{"fast":[...],"agent":[...]}}`; `POST /medic/api/models` `{"fast","agent"}` sets `ProviderClass`/`BaseURL`/`Model` on `Medic.FastTier` and `ProviderClass` on `Medic.Agent` via `Ens.Director` and applies with `Ens.Director.UpdateProduction()`. Availability: `Jev` when `SYSTEMONE_API_KEY` and `SYSTEMONE_BASE_URL` are set; `Laya` when `LAYA_BASE_URL` is set (new env var, added to `docker-compose.yml` and `.env.example`); `Gemini` when `AIHUB_API_KEY` is set and `%AI.Agent` exists; `Mock` always.
- Web apps, created idempotently in `Medic.Setup.Run`: `/medic` serving static files from `/home/irisowner/medic/web` (default page `index.html`), and `/medic/api` dispatching to `Medic.API.Dispatch`; both in namespace `USER`, unauthenticated, application role `%All` (local demo; README states not for exposed hosts).

- [ ] **Step 1: Write the failing tests** in `tests/test_api.py`: `test_health`; `test_scenarios_have_labels_and_ascii_names` (≥4 scenarios, includes "Critical result", all `raw_message` ASCII); `test_triage_returns_trace` (set models to Mock/Mock, triage the critical-result scenario → action `escalate`, trace stages include `Gate` and `Policy`); `test_triage_rejects_empty_message` (400 with `error`); `test_triage_rejects_bad_fhir` (400); `test_triage_rejects_oversized` (200 000-character message → 400); `test_utf8_round_trip` (a case whose PID name is `Müller^José` → 200, response decodes as UTF-8 without `�`); `test_approve_then_conflict` (approve → 200 with `precedent` 1; again → 409); `test_override_reroute_needs_target` (400); `test_random_cases_clamped` (`n=50` → 10 items, each with `expected.action`).
- [ ] **Step 2: Run** `uv run python -m unittest tests/test_api.py -v` against the running container → failures (404).
- [ ] **Step 3: Implement** the routes, scenario and model helpers, web-app creation, the `Dockerfile` copy of `web/`, the `LAYA_BASE_URL` env var, and two `Doctor` checks (`Web app /medic`, `Web app /medic/api`).
- [ ] **Step 4: Rebuild and run** the tests → all pass; `Doctor` shows no `[FAIL]`.
- [ ] **Step 5: Commit** `feat: Medic REST API and /medic web applications`.

### Task 5: Front-end data layer and browser mock models

**Files:**
- Create: `web/js/source.js`, `web/js/mock.js`, `web/data/bundle.json` (initial bundle recorded from the Task 4 API on Mock/Mock, `"models":{"fast":"Mock","agent":"Mock"}`; Task 8 replaces it)
- Test: `web/tests/mock.test.mjs`, `web/tests/source.test.mjs` (run with `node --test web/tests`)

**Interfaces:**
- Consumes: the Task 4 API and decision JSON shape.
- Bundle schema (`web/data/bundle.json`): `{"recordedAt","build","models":{"fast","agent"},"scenarios":[{"id","label","case","decision"}],"batches":[[{"case","expected","decision"}, ...5]]}`.
- Produces in `source.js`: `export async function detectSource(fetchImpl = fetch, timeoutMs = 2000)` → object with `mode` (`"live"|"replay"`) and `scenarios()`, `triage(caseObj)`, `randomCases(n)`, `approve(id)`, `override(id, action, target, reason)`, `models()`, `setModels(fast, agent)`. Live calls the API at the relative path `../medic/api` (resolved against `location`). Replay serves recorded decisions for recorded cases, runs `mock.js` for anything else, tags each decision `source: "replay"|"mock"`, and simulates approve/override in memory with the same trace/audit shapes, ` (simulated)` details, and `precedent: 0`.
- Produces in `mock.js`: `export function mockDecide(caseObj)` → decision JSON with trace, porting `Medic.Provider.JevMock` + `Medic.Provider.AgentMock` + the Agent gate (0.85 confidence, 0.6 severity, reroute always to agent) + `Medic.Policy.AutoApply` (threshold 0.9, dry run off).

- [ ] **Step 1: Write the failing tests**: `mock.test.mjs` — for the first case of each corruption type in `dataset/cases.jsonl`, `mockDecide` gives the same `action` as `final.action` in `data/results/mock/results.jsonl` for at least 15 of 16 types, and every trace ends with a `Policy` step. `source.test.mjs` — with a `fetch` stub that rejects, `detectSource` resolves to `mode:"replay"` in under 2 s; replay `triage` of a recorded case returns `source:"replay"`, of an edited copy `source:"mock"`; replay `approve` adds a `hum` step and an audit detail ending ` (simulated)`; a second approve rejects.
- [ ] **Step 2: Run** `node --test web/tests` → failures.
- [ ] **Step 3: Implement** `source.js` and `mock.js`.
- [ ] **Step 4: Run** `node --test web/tests` → all pass.
- [ ] **Step 5: Commit** `feat: front-end data layer with live/replay modes and browser mock models`.

### Task 6: The hub page

**Files:**
- Create: `web/index.html` (replaces placeholder), `web/css/hub.css`, `web/js/hub.js`, `web/reference/hub-v4.html` (copy of the approved mockup)
- Test: `web/tests/hub.test.mjs` (pure helpers only)

**Interfaces:**
- Consumes: `detectSource` and the decision/trace/audit shapes (Task 5).
- Produces in `hub.js` (exported pure helpers): `stepRows(trace)` → `[{n,stage,status,value,detail}]`; `overruled(decision)` → `true` when the first (fast-tier) step's action word differs from the final action; `kpis(rows)` → `{correct, total, fastShare, costPerDecision, medianMs}` over `[{expected, decision}]`.

Page behaviour, matching `web/reference/hub-v4.html`: scenario chips from `scenarios()` (four named ones plus a "More" chip revealing the rest) with the live wire animation; device screen with the mode label (`Live` / `Replay of a real run` / `Mock`), elapsed time, an `Agent overruled <fast provider>` badge from `overruled()`, numbered coloured steps, and a drawer showing a step's `detail` on click; during a live triage the screen shows a pulsing `Agent thinking… <seconds>` row until the response arrives; knobs cycling `models().available` and calling `setModels` (replay: recorded providers or Mock); decision card; outcome card with Approve/Override (2×2 action grid; reroute asks for a target from the routing table); audit trail; `Saved as a precedent` note only when the action result has `precedent:1`; a `Run a batch of 5` button that runs `randomCases(5)` one by one through `triage`, shows each in the device, and appends rows (case, expected, decided, ✓/✗, time, cost) to a batch list under the hub; KPI strip from `kpis()` over batch rows, showing `—` before any batch.

- [ ] **Step 1: Write the failing test** `hub.test.mjs`: `stepRows` numbers from 1; `overruled` true for Jev `resend` + final `escalate`, false when they match; `kpis` on three rows with 2 correct → `correct 2, total 3`, `medianMs` the middle value; `kpis([])` → `total 0`.
- [ ] **Step 2: Run** `node --test web/tests` → failure.
- [ ] **Step 3: Implement** `index.html`, `hub.css`, `hub.js`.
- [ ] **Step 4: Verify**: `node --test web/tests` passes; open `http://localhost:52773/medic/index.html` in the built-in browser at 1280×800 and 375×812 → no horizontal page scroll, no text overflowing a card, mode label `Live`; serve `web/` statically (`uv run python -m http.server -d web 8090`) → mode `Replay of a real run`, no console errors; live: Critical result → Approve shows the blue step, the simulated audit line and the precedent note; a batch of 5 on Mock/Mock completes and fills the KPI strip.
- [ ] **Step 5: Commit** `feat: hub page with trace, actions, batches and KPIs`.

### Task 7: Build your own

**Files:**
- Create: `web/js/builder.js`
- Modify: `web/index.html`, `web/js/hub.js`, `web/css/hub.css`
- Test: `web/tests/builder.test.mjs`

**Interfaces:**
- Consumes: `source.triage` (Task 5), hub rendering (Task 6).
- Produces: `export function buildCase(base, edits)` → a case object (`format`, `raw_message`, `error_text`, `context.endpoint.{up, down_minutes}`) with `case_id` `"custom-<timestamp>"`; `export function validateCase(c)` → array of messages for: empty message, FHIR that is not JSON, over 100 000 characters, negative minutes down; `[]` when valid.

The dashed chip opens a panel: starting-scenario dropdown, message textarea (pre-filled from the base case; HL7 `\r` shown as new lines and restored on submit), error text, endpoint up/down toggle with minutes. "Run" validates, then triages and renders like any scenario; in replay mode the result is labelled `Mock`.

- [ ] **Step 1: Write the failing tests**: `buildCase` restores `\r` segment separators for HL7; `validateCase` returns one message per invalid input above and `[]` for a valid case.
- [ ] **Step 2: Run** → failures.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** `node --test web/tests` passes; in the browser, set a timeout case's endpoint to down 600 min with an `HH` result → decision becomes escalate (live and mock); an empty message shows the validation text and sends no request.
- [ ] **Step 5: Commit** `feat: build-your-own scenario panel`.

### Task 8: Recording real runs for the public page

**Files:**
- Create: `eval/record.py`
- Test: `eval/test_record.py`

**Interfaces:**
- Consumes: the Task 4 API (`scenarios`, `triage`, `cases/random`, `models`).
- Produces: `record(base_url: str, batches: int, out: Path, opener=urllib.request.urlopen) -> dict` writing the Task 5 bundle schema; CLI `uv run python eval/record.py --batches 3 --out web/data/bundle.json`.

The script stamps `models`, `build` and `recordedAt`, triages every scenario, then runs `batches` batches of 5 from `cases/random`. A decision whose trace has an `unavailable` step is retried up to twice with a 20 s pause and never written, so rate-limit failures are not recorded as real decisions.

- [ ] **Step 1: Write the failing test** with a fake opener serving canned API responses: output has the bundle keys; `batches=2` → 2 batches of 5; an `unavailable` decision is retried and not written.
- [ ] **Step 2: Run** `uv run python -m unittest eval/test_record.py -v` → failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test → pass; then record for real on build 154 with Jev + Gemini: `uv run python eval/record.py --batches 3 --out web/data/bundle.json` → 16 scenarios, 3 batches, `models` `Jev`/`Gemini`; reload the static page → chips replay these runs.
- [ ] **Step 5: Commit** `feat: record real runs into the public page bundle` (includes `web/data/bundle.json`).

### Task 9: Publishing and docs

**Files:**
- Create: `.github/workflows/pages.yml`
- Modify: `README.md`

`pages.yml`: trigger `workflow_dispatch` only; one job runs `node --test web/tests`, then uploads `web/` with `actions/upload-pages-artifact` and deploys with `actions/deploy-pages`, both pinned to a version tag.

README: a "For judges: two minutes" section at the top (public link placeholder `https://<user>.github.io/<repo>/` until published; local `http://localhost:52773/medic/index.html`; what to click: Critical result → Approve, Run a batch of 5, Build your own); the Live/Replay/Mock labels explained; the `/medic` web apps being unauthenticated for local demo only; how to re-record with `eval/record.py`.

- [ ] **Step 1: Verify** the workflow: if `actionlint` is installed, `actionlint .github/workflows/pages.yml` reports nothing; otherwise compare it line by line with GitHub's "Static HTML" Pages starter workflow (permissions `pages: write`, `id-token: write`; `environment: github-pages`).
- [ ] **Step 2: Verify** each local command in the new README section by running it once.
- [ ] **Step 3: Commit** `docs: judge quick-start; Pages workflow (manual)`.
