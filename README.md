# Interop Medic

An agent that triages failed HL7 v2 and FHIR messages in InterSystems IRIS Interoperability.
For each errored or suspended message it decides one of **resend**, **fix and resend**,
**reroute**, **quarantine** or **escalate**, with a confidence, a severity, a rationale and a
proposed fix.

> **Status:** this runs fully offline with mock providers. The fast tier can call Jev or Laya. The
> AI Hub agent (`Medic.AIHub.TriageAgent`) is written, but it hasn't been run yet: it only compiles
> on the AI Hub Early Access build.

## How it works

```
Medic.DemoFeed ──> Medic.Triage (BPL) ──> Medic.Agent ──> Medic.FastTier
 (case files)       policy + dry run       │  1. ask the fast tier (Jev, Laya or mock)
                                           │  2. confident & low severity? accept it
                                           └  3. otherwise run the tool-using agent
```

Every decision goes through `Medic.Agent`. The fast tier is the agent's first step, not a bypass.
When it is confident and the case is low-stakes, the agent stops there; reroutes always go to the
full agent, because only its tools can name a target. Otherwise the agent runs with the fast
answer as a hint. `Medic.Policy.AutoApply` then decides whether the decision can be applied
without a person. `DryRun` is on by default.

| Setting | Item | Default |
|---|---|---|
| `ProviderClass` | Medic.FastTier | `MEDIC_FAST_PROVIDER`, else `Medic.Provider.JevMock` |
| `ProviderClass` | Medic.Agent | `MEDIC_AGENT_PROVIDER`, else `Medic.Provider.AgentMock` |
| `FastConfidence`, `FastSeverityCeiling` | Medic.Agent | 0.85, 0.6 |
| `AutoApplyThreshold`, `DryRun` | Medic.Triage | 0.9, on |

## Run it

You need Docker and [uv](https://docs.astral.sh/uv/). The Python scripts use only the standard
library; `uv sync` creates `.venv` with a matching Python.

```bash
uv sync
cp .env.example .env            # optional: your own IRIS password, fast-tier settings
uv run python dataset/generate.py --synthea dataset/synthea --cases-dir data/cases
docker compose up -d --build
uv run python dataset/feed.py --count 20 --rate 1
```

`feed.py` drips a shuffled mix of failed messages into the production. Use `--only
outage_critical_result,patient_mismatch` to show the hard cases.

Open the Management Portal at http://localhost:52773/csp/user/EnsPortal.ProductionConfig.zen and
look at the Visual Trace for each message. If ports 52773 or 1972 are taken, set `MEDIC_WEB_PORT`
and `MEDIC_SS_PORT`.

**Signing in.** Use `_SYSTEM` with the `IRIS_PASSWORD` from `.env`, or `SYS` if none is set.

- **No change-password prompt:** `_SYSTEM`, `SuperUser` and `Admin` are never forced to change
  their password.
- **When `IRIS_PASSWORD` is applied:** the first time the container starts, and again only after you
  change it in `.env`. A password changed in the portal survives restarts.
- **Recreated containers:** recreating the container (`docker compose down`, or a rebuild) starts
  again from the image.

**Readiness report.** To check the production, providers, routing table, mounts and accounts:

```bash
docker exec interop-medic iris session IRIS -U USER "##class(Medic.Setup).Doctor()"
```

### With AI Hub (Early Access build 154)

AI Hub is only in the Early Access Community build. Download it from the
[EAP portal](https://evaluation.intersystems.com/Eval/early-access/AIHub) ("AI Hub" program),
then load it, retag it and build with it:

```bash
docker image load -i irishealth-community-2026.3.0AI.154.0-docker.tar.gz
docker images
docker tag <loaded image name> irishealth-community:2026.3.0AI.154.0
IRIS_IMAGE=irishealth-community:2026.3.0AI.154.0 docker compose up -d --build
```

Without it, the default community image runs everything with the mock providers.

### Agent tier: the AI Hub agent

`Medic.AIHub.TriageAgent` is an AI Hub `%AI.Agent`. Its system prompt sets out the five actions
and the safety rules, and it must answer with one JSON decision. Its tools, in
`Medic.AIHub.ToolSet`, are all read-only:

- **`ValidateHL7`:** parses the message and checks its structure.
- **`GetRoutingRule` and `ClosestRoute`:** look up the routing table, including the closest match
  for a misspelt receiver.
- **`CheckEndpoint`:** reads a target's queue depth.

Two policies sit on the agent's tool manager:

- **`Medic.AIHub.ReadOnlyPolicy`** allows only those tools. The agent can read, but it never resends
  or edits anything. Applying a decision stays with `Medic.Policy.AutoApply` or a person.
- **`Medic.AIHub.ToolTrace`** records each tool call. The decision's rationale lists the tools that
  ran, and token use becomes the decision's cost.

`Medic.Provider.AIHubAgent` runs the agent once per message, with the fast tier's verdict as a
hint, and checks the reply. A reply with no JSON or an unknown action is rejected. A reroute with
no target becomes an escalation. Without AI Hub, or on any agent error, the case escalates with
zero confidence rather than failing.

The AI Hub classes are in `src-aihub/` and are compiled only when the image has `%AI.Agent`. The
default community image skips them, and the mock agent is used.

To use it, set `IRIS_IMAGE` to the build 154 image, then add to `.env`:

```bash
MEDIC_AGENT_PROVIDER=Medic.Provider.AIHubAgent
AIHUB_PROVIDER=openai
AIHUB_MODEL=<model>
AIHUB_API_KEY=<key>
```

### Fast tier: mock, Jev or Laya

Jev (TypeSafe) and Laya (open weights, Apache 2.0) use the same `POST /v1/systemone` API, so one
provider, `Medic.Provider.SystemOne`, handles both. It sends one request per message with three
typed questions:

- the action (a choice),
- the severity (a score), and
- whether acting could attach data to the wrong patient (a yes/no probability).

If that wrong-patient probability is 0.7 or higher, the decision is forced to escalate. If the
server is down or replies badly, the case goes to the agent instead of failing.

Put the settings in `.env` (copied from `.env.example`, git-ignored):

| Fast tier | `.env` |
|---|---|
| Mock (default, offline) | nothing |
| Local Laya (`laya-serve`, or `ollaya` on 11435) | `MEDIC_FAST_PROVIDER=Medic.Provider.SystemOne`<br>`SYSTEMONE_BASE_URL=http://host.docker.internal:8000`<br>`SYSTEMONE_PRICE_PER_MTOK=0` |
| Jev (hosted) | `MEDIC_FAST_PROVIDER=Medic.Provider.SystemOne`<br>`SYSTEMONE_BASE_URL=https://api.typesafe.ai`<br>`SYSTEMONE_API_KEY=...`<br>`SYSTEMONE_MODEL=jev-latest` (required)<br>`SYSTEMONE_PRICE_PER_MTOK=0.042` |

`SYSTEMONE_MODEL` picks a Laya checkpoint (`english`, `multilingual`, `typed-decisions`). The same
values can be set on `Medic.FastTier` in the Management Portal, with the key stored as
Interoperability credentials; portal settings take precedence over env vars.

Run Laya locally with `pip install "laya[serve]"` then `laya-serve`. See the upstream docs for GPU
and Docker options.

To check the plumbing without either model, run `uv run python eval/fake_systemone.py` and point
`SYSTEMONE_BASE_URL` at `http://host.docker.internal:8765`.

Confidence from different models is not comparable, so re-run the eval after switching. The
auto-apply threshold is fitted per model.

### Web page and REST API

The image serves a static page at `http://localhost:52773/medic/index.html` (this IRIS build has no default-page setting, so the bare `/medic/` is a 404) and a same-origin REST API at `/medic/api` (health, scenarios, random cases, triage, approve/override, model switch). Both web applications are unauthenticated with role `%All`: this is a local demo, do not expose the container to a network. `LAYA_BASE_URL` (optional) adds a "Laya" choice to the fast-tier model switch. API tests: `uv run python -m unittest tests/test_api.py -v`.

## Eval

```bash
uv run python eval/run.py
```

This sends all 450 cases through the running production twice: once through the full pipeline
and once to the fast tier alone, as a comparison. Results go to `data/results/<tag>/`, where the
tag defaults to the fast-tier provider (`jevmock`, `systemone`, ...) or comes from `--tag laya-local`.
That way runs with different models sit side by side. The report shows accuracy per corruption type, which tier decided,
latency and estimated cost, and an **auto-apply threshold with a guarantee**:

- The threshold is chosen on the calibration split by Learn-then-Test with a Bonferroni
  correction over a fixed grid, using a Clopper-Pearson bound.
- With probability at least 1 − δ (default 90%), auto-applied decisions are wrong at most α of
  the time.
- The threshold is then checked on the held-out test split.
- Escalations are never auto-applied.

With the mock providers the pipeline scores 100% and the mock fast tier alone 64.7%, because the
mock fast tier can't see context: critical results during outages, ambiguous dates, and receivers
that don't resolve to a route. These numbers only show the harness works, since the mocks were
written knowing the labels. Real numbers come from re-running with Jev or Laya and the AI Hub agent.

Tests:

```bash
uv run python -m unittest eval/test_score.py dataset/test_generate.py
docker exec -i interop-medic iris session IRIS -U USER <<< 'set ^UnitTestRoot="/tmp" do ##class(%UnitTest.Manager).DebugRunTestCase("","Medic.Test.SystemOne","","") do ##class(%UnitTest.Manager).DebugRunTestCase("","Medic.Test.AIHubAgent","","")'
```

## Dataset

`dataset/generate.py` writes 16 corruption types × N synthetic cases (reroutes weighted 3×), each
with a known correct action. With `--synthea dataset/synthea`, patients and lab results come from
[Synthea](https://github.com/synthetichealth/synthea), so names, ages and values look realistic.

- **Patients:** 300 Synthea patients.
- **Lab results:** their real potassium, sodium, glucose, haemoglobin, calcium, urea and chloride
  results.
- **Critical results:** Synthea values are almost all in range, so critical results are derived by
  pushing a real result past its critical limit.
- **The committed sample:** `dataset/synthea` is about 220 KB and keeps only ID, birth date, name and
  sex, plus lab results. To rebuild it from a full Synthea CSV export, run
  `uv run python dataset/synthea_sample.py --src <export>/csv`.
- **Without `--synthea`:** the generator uses its own made-up patients. Some cases share an error message but need different actions depending on context. For
example, a timeout is normally a resend, but a critical potassium result stuck behind a 4-hour
outage needs a person. Cases are split by hash into `calibration` (60%) and `test` (40%).

```bash
uv run python -m unittest dataset/test_generate.py
```

All data is synthetic. Don't add real messages.
