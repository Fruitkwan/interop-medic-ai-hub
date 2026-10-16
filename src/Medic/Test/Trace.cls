/// Unit tests for the structured decision trace.
/// Run: do ##class(%UnitTest.Manager).DebugRunTestCase("", "Medic.Test.Trace", "", "")
Class Medic.Test.Trace Extends %UnitTest.TestCase
{

Method TestAddStepShape()
{
	set d = ##class(Medic.Msg.Decision).%New()
	do d.AddStep("Jev", "ok", "resend 0.91", "fast pass", 12)
	do d.AddStep("Gate", "warn", "to agent", "confidence 0.42 < 0.85")
	set steps = d.Steps()
	do $$$AssertEquals(steps.%Size(), 2)
	set first = steps.%Get(0)
	do $$$AssertEquals(first.stage, "Jev")
	do $$$AssertEquals(first.status, "ok")
	do $$$AssertEquals(first.value, "resend 0.91")
	do $$$AssertEquals(first.detail, "fast pass")
	do $$$AssertEquals(first.ms, 12)
	do $$$AssertEquals(steps.%Get(1).ms, 0)
}

Method TestCopyFromKeepsTrace()
{
	set a = ##class(Medic.Msg.Decision).%New()
	do a.AddStep("Mock", "ok", "resend 0.90")
	set b = ##class(Medic.Msg.Decision).%New()
	do b.CopyFrom(a)
	do $$$AssertEquals(b.Steps().%Size(), 1)
	do $$$AssertEquals(b.Steps().%Get(0).stage, "Mock")
}

Method TestAgentMockAddsSteps()
{
	set req = ##class(Medic.Msg.FailedMessage).%New()
	set req.CaseId = "t1"
	set req.ErrorText = "no routing rule for receiver 'EPRR'"
	do req.RawMessage.Write("MSH|^~\&|A|B|C|D|20260101||ADT^A01|1|P|2.5")
	set req.ContextJSON = "{""routing_table"":{""EPR"":""Medic.To.EPR"",""LIS"":""Medic.To.LIS""}}"
	set d = ##class(Medic.Msg.Decision).%New()
	do $$$AssertStatusOK(##class(Medic.Provider.AgentMock).Decide(req, d))
	set steps = d.Steps(), stages = "", last = ""
	set it = steps.%GetIterator()
	while it.%GetNext(, .s) { set stages = stages_","_s.stage, last = s }
	do $$$AssertTrue(stages [ ",ClosestRoute", "has ClosestRoute step: "_stages)
	do $$$AssertEquals(last.stage, "Agent")
	do $$$AssertEquals($extract(last.value, 1, 7), "reroute", "Agent value: "_last.value)
}

Method TestUnavailableStep()
{
	// On an AI Hub build the agent class exists and would call a real model.
	quit:##class(%Dictionary.CompiledClass).%ExistsId("Medic.AIHub.TriageAgent")
	set req = ##class(Medic.Msg.FailedMessage).%New()
	set req.ErrorText = "timed out"
	do req.RawMessage.Write("MSH|^~\&|A|B|C|D|20260101||ADT^A01|1|P|2.5")
	set d = ##class(Medic.Msg.Decision).%New()
	do $$$AssertStatusOK(##class(Medic.Provider.AIHubAgent).Decide(req, d))
	set steps = d.Steps()
	set last = steps.%Get(steps.%Size() - 1)
	do $$$AssertEquals(last.stage, "Agent")
	do $$$AssertEquals(last.value, "unavailable")
	do $$$AssertEquals(last.status, "bad")
}

}
