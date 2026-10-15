# Interop Medic

An agent that triages failed HL7 v2 and FHIR messages in InterSystems IRIS Interoperability.
For each errored or suspended message it decides one of **resend**, **fix and resend**,
**reroute**, **quarantine** or **escalate**, with a confidence, a severity, a rationale and a
proposed fix.

> Status: skeleton. Runs fully offline with mock providers. The fast tier can already call Jev
> or Laya; the AI Hub agent (`Medic.Provider.AIHubAgent`) is still a stub.

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
| `ProviderClass` | Medic.Agent | `Medic.Provider.AgentMock` |
| `FastConfidence`, `FastSeverityCeiling` | Medic.Agent | 0.85, 0.6 |
| `AutoApplyThreshold`, `DryRun` | Medic.Triage | 0.9, on |

## Run it

```bash
python dataset/generate.py --n-per-type 25 --seed 7 --cases-dir data/cases
docker compose up -d --build
cp data/cases/outage_critical_result-7-000*.json data/in/
```

Open the Management Portal at http://localhost:52773/csp/user/EnsPortal.ProductionConfig.zen
(`_SYSTEM` / `SYS` on the community image) and look at the Visual Trace for each message.
If ports 52773 or 1972 are taken, set `MEDIC_WEB_PORT` and `MEDIC_SS_PORT`.

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

### Fast tier: mock, Jev or Laya

Jev (TypeSafe) and Laya (open weights, Apache 2.0) use the same `POST /v1/systemone` API, so one
provider, `Medic.Provider.SystemOne`, handles both. It sends one request per message with three
typed questions:

- the action (a choice),
- the severity (a score), and
- whether acting could attach data to the wrong patient (a yes/no probability).

If that wrong-patient probability is 0.7 or higher, the decision is forced to escalate. If the
server is down or replies badly, the case goes to the agent instead of failing.

Put the settings in a git-ignored `.env` file next to `docker-compose.yml`:

| Fast tier | `.env` |
|---|---|
| Mock (default, offline) | nothing |
| Local Laya (`laya-serve`, or `ollaya` on 11435) | `MEDIC_FAST_PROVIDER=Medic.Provider.SystemOne`<br>`SYSTEMONE_BASE_URL=http://host.docker.internal:8000`<br>`SYSTEMONE_PRICE_PER_MTOK=0` |
| Jev (hosted) | `MEDIC_FAST_PROVIDER=Medic.Provider.SystemOne`<br>`SYSTEMONE_BASE_URL=<TypeSafe API base URL>`<br>`SYSTEMONE_API_KEY=...`<br>`SYSTEMONE_PRICE_PER_MTOK=0.042` |

`SYSTEMONE_MODEL` picks a Laya checkpoint (`english`, `multilingual`, `typed-decisions`). The same
values can be set on `Medic.FastTier` in the Management Portal, with the key stored as
Interoperability credentials; portal settings take precedence over env vars.

Run Laya locally with `pip install "laya[serve]"` then `laya-serve`. See the upstream docs for GPU
and Docker options.

To check the plumbing without either model, run `python eval/fake_systemone.py` and point
`SYSTEMONE_BASE_URL` at `http://host.docker.internal:8765`.

Confidence from different models is not comparable, so re-run the eval after switching. The
auto-apply threshold is fitted per model.

## Eval

```bash
python eval/run.py
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
python -m unittest eval/test_score.py dataset/test_generate.py
docker exec -i interop-medic iris session IRIS -U USER <<< 'do ##class(%UnitTest.Manager).DebugRunTestCase("","Medic.Test.SystemOne","","")'
```

## Dataset

`dataset/generate.py` writes 16 corruption types × N synthetic cases (reroutes weighted 3×), each
with a known correct action. Some cases share an error message but need different actions depending on context. For
example, a timeout is normally a resend, but a critical potassium result stuck behind a 4-hour
outage needs a person. Cases are split by hash into `calibration` (60%) and `test` (40%).

```bash
python -m unittest dataset/test_generate.py
```

All data is synthetic. Don't add real messages.
