/// Unit tests for Medic.Provider.SystemOne: request shape, response mapping, guardrail, fail-safe.
/// Run: do ##class(%UnitTest.Manager).DebugRunTestCase("", "Medic.Test.SystemOne", "", "")
Class Medic.Test.SystemOne Extends %UnitTest.TestCase
{

ClassMethod Request() As Medic.Msg.FailedMessage
{
	set req = ##class(Medic.Msg.FailedMessage).%New()
	set req.CaseId = "t-1", req.Format = "hl7v2"
	set req.ErrorText = "ERROR #5023: Remote TCP connection timed out after 30 seconds (Medic.To.EPR)"
	do req.RawMessage.Write("MSH|^~\&|LIS|MEDIC_HOSP|EPR|MEDIC_HOSP|20261001120000||ORU^R01^ORU_R01|MSG1|P|2.5"_$char(13)_"PID|1||12345678^^^MEDIC^MR||Testwood^Alex||19850312|F"_$char(13))
	set req.ContextJSON = {"routing_table": {"EPR": "Medic.To.EPR", "LAB": "Medic.To.LIS"}, "endpoint": {"name": "Medic.To.EPR", "up": false, "down_minutes": 12}}.%ToJSON()
	quit req
}

ClassMethod Response(pAction As %String, pConf As %Numeric, pScore As %Numeric, pIdRisk As %Numeric) As %DynamicObject
{
	set probabilities = {}
	do probabilities.%Set(pAction, pConf)
	quit {
		"model": "english",
		"answers": {
			"action": {"type": "choice", "choice": (pAction), "probabilities": (probabilities), "confidence": 0.4, "answer_confidence": (pConf)},
			"severity": {"type": "score", "score": (pScore)},
			"identity_risk": {"type": "noul", "noul": (pIdRisk)}
		},
		"usage": {"input_tokens": 400, "output_tokens": 0}
	}
}

Method TestBuildRequest()
{
	set body = ##class(Medic.Provider.SystemOne).BuildRequest(..Request(), "multilingual")
	do $$$AssertTrue(body.state [ "Error: ERROR #5023", "state starts with the error")
	do $$$AssertTrue(body.state [ "Endpoint Medic.To.EPR: down, down 12 min", "endpoint health included")
	do $$$AssertTrue(body.state [ "EPR -> Medic.To.EPR", "routing table included")
	do $$$AssertTrue(body.state [ "PID|1||12345678", "message included")
	do $$$AssertEquals(body.model, "multilingual")
	do $$$AssertEquals(body.questions.action.type, "choice")
	set n = 0, it = body.questions.action.criteria.%GetIterator()
	while it.%GetNext(.key) { set n = n + 1 }
	do $$$AssertEquals(n, 5, "five actions offered")
	do $$$AssertEquals(body.questions.severity.criteria.%Size(), 5)
	do $$$AssertEquals(body.questions."identity_risk".type, "noul")
}

Method TestApplyAnswers()
{
	set d = ##class(Medic.Msg.Decision).%New()
	do ##class(Medic.Provider.SystemOne).ApplyAnswers(..Response("resend", 0.93, 1.2, 0.05), d, {"pricePerMTok": 0.042})
	do $$$AssertEquals(d.Action, "resend")
	do $$$AssertEquals(d.Confidence, 0.93, "gates on answer_confidence, not confidence")
	do $$$AssertEquals(d.Severity, 0.3, "score 1.2 of 4 -> 0.3")
	do $$$AssertEquals(d.Provider, "Medic.Provider.SystemOne:english")
	do $$$AssertEquals(d.CostUSD, 400 * 0.042 / 1000000)
}

Method TestIdentityRiskEscalates()
{
	set d = ##class(Medic.Msg.Decision).%New()
	do ##class(Medic.Provider.SystemOne).ApplyAnswers(..Response("fix_and_resend", 0.9, 1, 0.85), d)
	do $$$AssertEquals(d.Action, "escalate")
	do $$$AssertEquals(d.Confidence, 0.85)
	do $$$AssertTrue(d.Severity >= 0.9)
}

Method TestFallsBackToProbability()
{
	set resp = ..Response("quarantine", 0.77, 0, 0)
	do resp.answers.action.%Remove("answer_confidence")
	set d = ##class(Medic.Msg.Decision).%New()
	do ##class(Medic.Provider.SystemOne).ApplyAnswers(resp, d)
	do $$$AssertEquals(d.Confidence, 0.77)
}

Method TestUnreachableServerFailsSafe()
{
	set d = ##class(Medic.Msg.Decision).%New()
	set sc = ##class(Medic.Provider.SystemOne).Decide(..Request(), d, "", {"baseUrl": "http://127.0.0.1:9", "timeout": 2})
	do $$$AssertStatusOK(sc, "no error raised into the production")
	do $$$AssertEquals(d.Action, "escalate")
	do $$$AssertEquals(d.Confidence, 0)
	do $$$AssertTrue(d.Rationale [ "unavailable")
}

}
