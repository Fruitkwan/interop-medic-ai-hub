/// Unit tests for Workflow review tasks and the LLM fields shown in the Visual Trace.
/// Run: do ##class(%UnitTest.Manager).DebugRunTestCase("", "Medic.Test.Review", "", "")
Class Medic.Test.Review Extends %UnitTest.TestCase
{

Method TestTaskTextNamesTheProposal()
{
	set d = ##class(Medic.Msg.Decision).%New()
	set d.CaseId = "C-1", d.Action = "escalate", d.Confidence = 0.95, d.Severity = 0.9
	set d.Rationale = "Critical result undelivered", d.ProposedFix = "Call the ward"
	set r = ##class(Medic.Msg.ReviewRequest).From(d)
	do $$$AssertEquals(r.CaseId, "C-1")
	do $$$AssertEquals(r.Action, "escalate")
	set body = ##class(Medic.Process.Review).Body(r)
	do $$$AssertTrue(body [ "proposes escalate (confidence 0.95, severity 0.90)", body)
	do $$$AssertTrue(body [ "Proposed fix: Call the ward")
	do $$$AssertEquals(##class(Medic.Process.Review).Subject("C-1"), "Interop Medic case C-1")
	do $$$AssertEquals(##class(Medic.Process.Review).DecisionId("no-such-case-zz"), "")
}

/// A case has fast, agent and final rows in no fixed order; the answer must reach the final one.
Method TestFindsTheRowThePolicyHeld()
{
	set case = "ZZ-REVIEW-"_$translate($system.Util.CreateGUID(), "{}-", "")
	set final = ##class(Medic.Msg.Decision).%New()
	set final.CaseId = case
	do final.AddStep("Agent", "ok", "escalate 0.90")
	do final.AddStep("Policy", "warn", "held for a person")
	do $$$AssertStatusOK(final.%Save())
	for stage = "Mock", "Agent" {
		set other = ##class(Medic.Msg.Decision).%New()
		set other.CaseId = case
		do other.AddStep(stage, "ok", "resend 0.80")
		do $$$AssertStatusOK(other.%Save())
		set ids(stage) = other.%Id()
	}
	do $$$AssertEquals(##class(Medic.Process.Review).DecisionId(case), final.%Id(), "not the higher-numbered rows")
	do ##class(Medic.Msg.Decision).%DeleteId(final.%Id())
	do ##class(Medic.Msg.Decision).%DeleteId(ids("Mock")), ##class(Medic.Msg.Decision).%DeleteId(ids("Agent"))
}

/// The Triage BPL copies the agent's decision into its own response: the LLM fields must survive.
Method TestCopyFromKeepsLLMFields()
{
	set a = ##class(Medic.Msg.Decision).%New()
	set a.Model = "gemma4", a.InputTokens = 1200, a.OutputTokens = 85, a.Prompt = "Triage this", a.Completion = "{""action"":""resend""}"
	set a.ToolCalls = "[{""tool"":""CheckEndpoint"",""ms"":3}]"
	set b = ##class(Medic.Msg.Decision).%New()
	do b.CopyFrom(a)
	for prop = "Model", "InputTokens", "OutputTokens", "Prompt", "Completion", "ToolCalls" {
		do $$$AssertEquals($property(b, prop), $property(a, prop), prop)
	}
	do $$$AssertEquals(##class(Medic.Actions).DecisionJSON(b).inputTokens, 1200)
}

}
