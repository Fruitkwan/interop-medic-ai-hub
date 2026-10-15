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

## Dataset

`dataset/generate.py` writes 15 corruption types × N synthetic cases, each with a known correct
action. Some cases share an error message but need different actions depending on context. For
example, a timeout is normally a resend, but a critical potassium result stuck behind a 4-hour
outage needs a person. Cases are split by hash into `calibration` (60%) and `test` (40%).

```bash
python -m unittest dataset/test_generate.py
```

All data is synthetic. Don't add real messages.
