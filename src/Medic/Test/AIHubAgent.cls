/// Unit tests for Medic.Provider.AIHubAgent's parsing, prompt and fail-safe. They need no AI Hub.
/// Run: do ##class(%UnitTest.Manager).DebugRunTestCase("", "Medic.Test.AIHubAgent", "", "")
Class Medic.Test.AIHubAgent Extends %UnitTest.TestCase
{

Method TestParsesPlainJSON()
{
	set d = ##class(Medic.Msg.Decision).%New()
	set sc = ##class(Medic.Provider.AIHubAgent).ParseDecision("{""action"": ""resend"", ""confidence"": 0.92, ""severity"": 0.3, ""rationale"": ""Endpoint timed out"", ""proposed_fix"": ""Resend unchanged"", ""reroute_target"": """"}", d)
	do $$$AssertStatusOK(sc)
	do $$$AssertEquals(d.Action, "resend")
	do $$$AssertEquals(d.Confidence, 0.92)
	do $$$AssertEquals(d.ProposedFix, "Resend unchanged")
}

Method TestToleratesFencesAndProse()
{
	set d = ##class(Medic.Msg.Decision).%New()
	set reply = "Here is my decision:"_$char(10)_"```json"_$char(10)_"{""action"": ""Reroute"", ""confidence"": 1.4, ""severity"": -1, ""rationale"": ""EPRR is EPR"", ""reroute_target"": ""Medic.To.EPR""}"_$char(10)_"```"
	do $$$AssertStatusOK(##class(Medic.Provider.AIHubAgent).ParseDecision(reply, d))
	do $$$AssertEquals(d.Action, "reroute", "action is case-insensitive")
	do $$$AssertEquals(d.RerouteTarget, "Medic.To.EPR")
	do $$$AssertEquals(d.Confidence, 1, "clamped to 1")
	do $$$AssertEquals(d.Severity, 0, "clamped to 0")
}

Method TestRerouteWithoutTargetEscalates()
{
	set d = ##class(Medic.Msg.Decision).%New()
	do $$$AssertStatusOK(##class(Medic.Provider.AIHubAgent).ParseDecision("{""action"": ""reroute"", ""confidence"": 0.9, ""severity"": 0.4, ""rationale"": ""typo""}", d))
	do $$$AssertEquals(d.Action, "escalate")
	do $$$AssertTrue(d.Confidence <= 0.5)
	do $$$AssertEquals(d.RerouteTarget, "")
}

Method TestRejectsBadReplies()
{
	set d = ##class(Medic.Msg.Decision).%New()
	do $$$AssertStatusNotOK(##class(Medic.Provider.AIHubAgent).ParseDecision("I think you should resend it.", d), "no JSON")
	do $$$AssertStatusNotOK(##class(Medic.Provider.AIHubAgent).ParseDecision("{""action"": ""delete""}", d), "unknown action")
	do $$$AssertStatusNotOK(##class(Medic.Provider.AIHubAgent).ParseDecision("{""action"": }", d), "broken JSON")
}

Method TestPromptIncludesHint()
{
	set req = ##class(Medic.Test.SystemOne).Request()
	set hint = ##class(Medic.Msg.Decision).%New()
	set hint.Action = "resend", hint.Confidence = 0.88, hint.Severity = 0.9, hint.Rationale = "Transport failure"
	set text = ##class(Medic.Provider.AIHubAgent).Prompt(req, hint)
	do $$$AssertTrue(text [ "Error: ERROR #5023")
	do $$$AssertTrue(text [ "Fast classifier verdict (a hint, not a fact): resend")
	do $$$AssertTrue(text [ "PID|1||12345678")
}

Method TestFailsSafeWithoutAIHub()
{
	quit:##class(%Dictionary.CompiledClass).%ExistsId("Medic.AIHub.TriageAgent")
	set d = ##class(Medic.Msg.Decision).%New()
	set sc = ##class(Medic.Provider.AIHubAgent).Decide(##class(Medic.Test.SystemOne).Request(), d)
	do $$$AssertStatusOK(sc)
	do $$$AssertEquals(d.Action, "escalate")
	do $$$AssertEquals(d.Confidence, 0)
	do $$$AssertTrue(d.Rationale [ "not installed")
}

}
