# Interop Medic: demo video script

About 3 minutes 30 seconds, roughly 480 spoken words. For the YouTube bonus and the Open Exchange
**YouTube URL** field.

## Before you record

- Rebuild so the page has the latest code: `docker compose up -d --build`.
- **Models:** Fast **Jev**, Agent **Gemini**. Local Gemma takes about 3 minutes a case, so don't
  use it on camera. Check Gemini's quota with one run first; if it is out, use **Mercury 2.5**.
- **Clean the Workflow inbox.** Every held decision opens a task, so test runs leave old ones. A
  rebuild clears them; do it last.
- Close other tabs, zoom the browser to 125%, and use a 1920×1080 window.
- Open three tabs: the page, the Message Viewer, and the Workflow inbox (sign in first).
- **Rehearse Critical result.** Scene 3 needs the agent to escalate. Gemma resent it in the recorded
  run, so don't film this scene from the replay, and rewrite it if your live model does the same.
- Do one full rehearsal run. Agent calls take 15 to 36 seconds: record them and cut the wait.
- Never show `.env` or a real key. For scene 6, type a fake key or blur it.

## Scene 1: the problem (0:00 to 0:20)

**Screen:** the page, Live badge visible, nothing selected.

> Every hospital integration engine has a queue of failed messages. Most only need a resend. But a
> few are a critical lab result stuck behind an outage, or data about to reach the wrong patient.
> Telling them apart at 3 a.m. is the hard part. Interop Medic does that triage inside InterSystems
> IRIS.

## Scene 2: how it works (0:20 to 0:45)

**Screen:** the README diagram under "How it works", then back to the page.

> It is an IRIS Interoperability production. A fast decision model answers first. A gate checks its
> confidence and the severity. Anything uncertain goes to an AI Hub agent, which checks the facts
> with read-only tools. It can look, but it can't change anything. Then a deterministic policy
> decides what may run alone, and a person reviews the rest.

## Scene 3: a critical result (0:45 to 1:30)

**Screen:** click **Critical result**. Cut the wait. Open each trace step as you mention it.

> Here is a hemoglobin result flagged critical, and the endpoint has been down for eight hours.
> The fast model says: resend. It's only sixty percent sure, so the gate passes it to the agent.
>
> The agent searches past decisions with IRIS Vector Search, validates the HL7, and checks the
> endpoint. It finds a critical value during a long outage, and it overrules the fast model:
> escalate. And the policy holds it for a person, because an escalation never runs alone.

## Scene 4: the human decides (1:30 to 2:00)

**Screen:** the Workflow inbox tab, open the task. Then either answer it there, or click **Approve**
on the page, and show the audit trail and the "Person" step.

> That held decision is also a task in the IRIS Workflow Engine, assigned to a reviewers role. A
> person can answer here, or on the page. Whoever decides first wins, it's recorded in the audit
> trail, and the case joins the precedent store, so the next similar failure can cite it.

## Scene 5: everything is traced (2:00 to 2:30)

**Screen:** Message Viewer, newest session, **Trace**. Click the `Medic.Agent` response. Scroll past
`Model`, `InputTokens`, `Prompt`, `ToolCalls`.

> Every model call is a message in the production, so the standard Visual Trace is the LLM trace.
> Here's the model, the tokens, the exact prompt, the raw reply, and each tool call with its
> arguments and timing. This implements Community idea DPI-I-689. No external tracing service, and
> the data stays in IRIS.

## Scene 6: any model, your own key (2:30 to 3:00)

**Screen:** open the **Fast** menu, then the **Agent** menu. Click **API keys**, type a fake key
into `anthropic`, **Save**, and show Claude turn on in the menu.

> Judges can try any model. The fast tier runs decision models: Jev, Nimble locally, or Inception's
> Mercury. The agent runs Gemini, Claude, ChatGPT, Grok, Mercury, or local Gemma and Qwen through
> AI Hub. Paste your own key here. It stays in your browser tab, it's used for one message at a
> time, and it's never stored.

## Scene 7: proof, and close (3:00 to 3:30)

**Screen:** **Run a batch of 5** (speed up the footage). Show the score strip. End on the GitHub
page.

> A batch scores the pipeline against labelled cases, and the page shows accuracy, cost and time.
> In our recorded run on a small local model, 19 of 31 decisions matched the expected action. Eight
> wrong decisions were confident enough to run alone, and the severity limit held seven for a person.
> The repository includes the dataset and the harness to measure any model yourself.
>
> Interop Medic: fast decisions, checked facts, and a person in charge of the risky ones. Thanks for
> watching.

## After recording

- Title: `Interop Medic: an AI Hub agent that triages failed HL7 and FHIR messages`
- Description: link the GitHub repo, the Open Exchange page, and idea DPI-I-689.
- Upload as Public or Unlisted, then add the link to the **YouTube URL** field on Open Exchange and
  to the top of the README.
