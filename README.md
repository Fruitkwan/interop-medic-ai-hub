# Interop Medic

An agent that triages failed HL7 v2 and FHIR messages in InterSystems IRIS Interoperability.
For each errored or suspended message it decides one of **resend**, **fix and resend**,
**reroute**, **quarantine** or **escalate**, with a confidence, a severity, a rationale and a
proposed fix.

> Status: skeleton. Runs fully offline with mock providers. The AI Hub agent
> (`Medic.Provider.AIHubAgent`) and the real Jev call (`Medic.Provider.JevHttp`) are stubs.

## How it works

```
Medic.DemoFeed ──> Medic.Triage (BPL) ──> Medic.Agent ──> Medic.Jev
 (case files)       policy + dry run       │  1. ask Jev (fast, typed)
                                           │  2. confident & low severity? accept it
                                           └  3. otherwise run the tool-using agent
```

Every decision goes through `Medic.Agent`. Jev is the agent's first step, not a bypass. When Jev
is confident and the case is low-stakes, the agent stops there. Otherwise it runs the full
tool-using agent with Jev's answer as a hint. `Medic.Policy.AutoApply` then decides whether the
decision can be applied without a person. `DryRun` is on by default.

| Setting | Item | Default |
|---|---|---|
| `ProviderClass` | Medic.Jev | `Medic.Provider.JevMock` |
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

## Eval

```bash
python eval/run.py
```

This sends all 450 cases through the running production twice: once through the full pipeline
and once to Jev alone, as a comparison. It writes `data/results/report.md` and
`data/results/curve.csv`. The report shows accuracy per corruption type, which tier decided,
latency and estimated cost, and an **auto-apply threshold with a guarantee**:

- The threshold is chosen on the calibration split by Learn-then-Test with a Bonferroni
  correction over a fixed grid, using a Clopper-Pearson bound.
- With probability at least 1 − δ (default 90%), auto-applied decisions are wrong at most α of
  the time.
- The threshold is then checked on the held-out test split.
- Escalations are never auto-applied.

With the mock providers the pipeline scores 100% and Jev alone 64.7%, because Jev can't see
context: critical results during outages, ambiguous dates, and receivers that don't resolve to
a route. These numbers only show the harness works, since the mocks were written knowing the
labels. Real numbers come from re-running with Jev and the AI Hub agent.

```bash
python -m unittest eval/test_score.py dataset/test_generate.py
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
