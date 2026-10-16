# Interop Medic — judge-facing web app: design

Date: 2026-10-16. Approved layout: `.superpowers/brainstorm/553-1792172282/content/hub-v4.html` (local mockup, git-ignored; copy it into the repo as the visual reference when building).

## Why

Judges for the InterSystems "AI Agents in Interoperability Workflows" contest have minutes, may never run our Docker setup, and cannot see an agent's reasoning in a Management Portal screenshot. The entry wins on one moment: a judge picks a failed message, watches it flow through the fast tier (Jev) and the AI Hub agent, and sees the agent check the facts with its tools, overrule a fast verdict on a patient-safety case, and hand it to a person with a concrete next step. Everything on the page serves that moment, plus proof that it holds up at scale (the eval scoreboard).

## Goals

- A judge understands what Interop Medic does within one minute, with no install and no keys.
- They can try other scenarios, including one they build themselves, and see the decision flow for each.
- They see the human-in-the-loop: what happens when a person approves or overrides.
- Every number shown is real (from batches actually run or replayed recordings), never a placeholder.
- Approved decisions become real precedents the agent can look up later (IRIS Vector Search).
- The same page also runs inside the Docker app, live against the real production.

## Non-goals

- Not a production operations console (no auth model, no multi-user, no message search).
- Not a replacement for the Management Portal or Visual Trace; it links to them in the Docker version.
- No editing of production settings from the page beyond the two model knobs.

## Anti-goals (would make it a failure even if it works)

- Text that overflows or crowds the cards; walls of explanation. Short labels, details on click.
- Implying something happened that didn't: "ward paged" must be labelled simulated; recorded runs labelled as replays; mock decisions labelled as mock.
- Showing mock results as if they were real model output.
- A demo that needs a key or the 11 GB AI Hub image just to look at it.

## The page (layout A "hub", approved as v4)

Full-width, five zones left to right, on a light dotted background, plus a dark KPI strip along the bottom:

1. **Failed messages** — scenario chips (endpoint timeout, critical result, misspelt receiver, wrong patient, and more from the 16 corruption types) and a dashed "+ Build your own" chip. Selecting a chip animates its connecting wire.
2. **The device** — a rounded "device" whose dark screen shows the trace as numbered steps (stage name left, short result right, coloured status dot: green ok, amber unsure, red risk, blue human). Top bar shows "Replay of a real run" / "Live" / "Mock", elapsed time, and an "Agent overruled Jev" badge when the agent's action differs from the fast tier's. Clicking a step opens a small drawer with its evidence (the HL7 segment, the tool result, the agent's reply). Two pill **knobs** under the screen pick the models: Fast (Jev / Laya / Mock) and Agent (Gemini / Mock).
3. **Decision card** — action pill (colour per action), severity bar, confidence bar.
4. **Outcome card** — either "✓ applied automatically" or "Awaiting a person" with the next step and **Approve / Override** buttons. Override offers the other actions as a 2×2 grid.
5. **Audit trail** — timestamped events for the selected message (Jev verdict, agent verdict, policy, person, production).

KPI strip: correct (n of N cases run), share decided on the fast path, cost per decision, median time. It accumulates over the **batches** run in this view (see below); it never shows a figure that wasn't produced by a run.

### Run a batch of 5 (owner's decision)

Instead of one long eval behind the numbers, the page has a **"Run a batch of 5"** button. Each press picks 5 random labelled cases from the dataset, sends them through the pipeline one after another (the device shows each one flowing, as for a single scenario), and adds them to a batch list: case, expected action, decided action, right/wrong, time, cost. The KPI strip updates from all batches run so far. A judge can stop after one batch or keep going; nothing forces the full 450-case run. The full eval stays available from the command line (`eval/run.py`) for whoever wants it.

### Person actions

- **Approve** → trace gains a blue step "You · approved"; outcome becomes the applied result; audit adds the approval and the production's action. Actions with no real downstream system in the demo (paging a ward) are labelled "(simulated)".
- **Override** → choose the correct action; pill changes; trace and audit record it as a correction. Corrections are stored so the eval can count them and the next calibration can use them. The page must not claim thresholds were re-fit live unless they actually are.
- Approved decisions are stored as precedents (see "Precedents" below).

### Build your own

A compact form: pick a starting scenario, then edit the message text (HL7 or FHIR), the error text, and the endpoint state (up/down, minutes down). Running it shows the same flow. Validation keeps it from posting obviously malformed input to the live API.

## Two ways to open it

| | Public link (GitHub Pages) | Inside the Docker app (`/medic/`, served by IRIS) |
|---|---|---|
| Scenario chips | Replay recorded real runs (Jev + Gemini on build 154) | Replay, or re-run live |
| Build your own | Runs on mock models in the browser | Runs through the real production with the configured models |
| Knobs | Switch between recorded providers where recordings exist, else mock | Switch providers live (Jev/Laya/Mock, Gemini/Mock) |
| Approve / Override | Simulated in the page, nothing persisted | Persisted in IRIS (audit table, corrections, precedents) |
| Run a batch of 5 | Replays recorded batches (real Jev + Gemini runs), then mock once recordings run out | Runs live through the production (about 5 × 19 s with the real agent) |
| KPIs | From the batches replayed in this visit | From the batches run in this visit |

One codebase: plain HTML/CSS/JS with no build step, so IRIS can serve it as static files and GitHub Pages can host it unchanged. The page detects whether the IRIS API is reachable and switches mode; the mode is always shown in the screen's top bar.

## What the back end must provide (Docker mode)

A REST API in IRIS (`/medic/api`, `%CSP.REST`), with the page and API on the same origin:

- `GET scenarios` — scenario list with a representative case each.
- `POST triage` — run one case (scenario case or a built one) through the real production synchronously; return the decision and its **structured trace**.
- `POST decisions/{id}/approve`, `POST decisions/{id}/override` — record the person's action; return the updated trace and audit events.
- `POST batch` — pick 5 random labelled cases and run them; returns each decision, trace and its expected action (the page can also call `triage` five times and stream progress; builder's choice).
- `GET/POST settings/models` — read and switch the fast-tier and agent providers.

**Structured trace (new).** Today a decision records only its outcome and a rationale with the tool names. The page needs each step: fast-tier verdict and confidence, gate outcome and why, each agent tool call with arguments and result summary, the agent's parsed reply, the policy outcome, and person actions — with timings. The tool-call data is already captured by `Medic.AIHub.ToolTrace`; it needs to be persisted with the decision.

## Recorded runs (for the public link)

A script runs the chosen scenarios and a handful of batches of 5 against the real models in Docker and writes a static JSON bundle (`web/data/`) with each case's trace and decision. The bundle is committed and served by GitHub Pages. Recordings say which models and build produced them and when.

## Constraints

- The real agent takes ~19 s per decision; the page must show progress during live runs and never block the replay mode on it.
- Keys stay server-side (`.env`); the public page never needs or holds a key.
- Synthetic data only (Synthea-based sample); some Synthea names contain a mis-encoded character, so recorded scenarios should use cases whose names render cleanly.
- Must work at laptop widths (1280 px) and degrade to a stacked layout on narrow screens.
- Contest: open source, README in English with install steps; submission window 26 Oct – 8 Nov 2026.

## Precedents

Real, by the owner's decision. Approving a decision, or overriding it with the corrected action, stores the case as a precedent in IRIS: the error text and a short context summary as a vector (IRIS Vector Search), with the final action and who decided it. The AI Hub agent gets a read-only tool, `SearchPrecedents`, returning the few most similar past cases and their final actions; its rationale names any precedent it relied on, and the trace shows the tool call like any other. The page's "Saved as a precedent" note only appears after the store actually succeeded.

Where the embeddings come from is the builder's call (for example Gemini embeddings through the already configured key, or an embedding model IRIS can call directly), with the constraint that mock mode still works without any key (for instance by falling back to matching the corruption signature). Precedents carry over to the eval only as an opt-in, so eval numbers stay comparable between runs.

## Left to the builder

Exact colours and spacing within the approved look; JS structure; how the static mock models are implemented in the browser (port of `JevMock`/`AgentMock` logic is fine); REST class and table names; how recorded bundles are generated and versioned.

## Calls I made (not decided by the owner)

- Plain HTML/CSS/JS, no framework or build step, so one copy serves both IRIS and GitHub Pages.
- "Build your own" on the public link uses browser-side mock models, labelled as mock.
- Person actions on the public link are simulated in the page and not persisted.
- Ward paging and similar downstream effects are simulated and labelled as such, also in Docker mode.
- On the public link, the knobs only offer providers that have recordings (today: Jev + Gemini, plus Mock); Laya appears only in Docker mode until it has recordings.
- Overriding to "reroute" asks for the target from the routing table, because a reroute without a target cannot be applied.
- Live runs use a synchronous `POST triage` with a progress state in the device screen; no job queue.
- The GitHub Pages site is published only after 26 Oct 2026, when the contest opens, alongside the public repo.
