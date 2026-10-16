/// Unit tests for person actions (approve / override), the audit trail and the precedent store.
/// Run: do ##class(%UnitTest.Manager).DebugRunTestCase("", "Medic.Test.Actions", "", "")
Class Medic.Test.Actions Extends %UnitTest.TestCase
{

Property Ids As %List;

/// A saved, unapplied (held) Decision with a unique case id.
Method NewHeld(pAction As %String = "escalate", pText As %String = "Connection refused by downstream host") As Medic.Msg.Decision
{
	set d = ##class(Medic.Msg.Decision).%New()
	set d.CaseId = "UT-"_$system.Util.CreateGUID()
	set d.Action = pAction
	set d.Confidence = 0.5
	set d.Severity = 0.9
	set d.Rationale = pText
	set d.DecidedBy = "agent"
	set d.AutoApplied = 0
	do d.AddStep("Jev", "ok", pAction_" 0.50")
	do d.AddPolicyStep(0.9, 0)
	do d.%Save()
	set ..Ids = ..Ids_$lb(d.%Id())
	quit d
}

Method OnAfterAllTests() As %Status
{
	set ptr = 0
	while $listnext(..Ids, ptr, id) {
		set case = ##class(Medic.Msg.Decision).%OpenId(id).CaseId
		do ##class(Medic.Msg.Decision).%DeleteId(id)
		&sql(DELETE FROM Medic_Data.Audit WHERE DecisionId = :id)
		&sql(DELETE FROM Medic_Data.Precedent WHERE CaseId = :case)
	}
	quit $$$OK
}

Method TestEmbedIsDeterministicAndUnit()
{
	set a = ##class(Medic.Data.Embed).Text("No routing rule matched MSH:5 'EPRR'")
	set b = ##class(Medic.Data.Embed).Text("No routing rule matched MSH:5 'EPRR'")
	do $$$AssertEquals(a, b, "same text gives same vector")
	do $$$AssertEquals($length(a, ","), 256)
	set sum = 0
	for i = 1:1:256 { set sum = sum + ($piece(a, ",", i) ** 2) }
	do $$$AssertTrue($zabs($zsqr(sum) - 1) < 0.001, "L2 norm is 1")
}

Method TestApproveEscalation()
{
	set d = ..NewHeld("escalate")
	set r = ##class(Medic.Actions).Approve(d.%Id())
	do $$$AssertEquals(r.ok, 1)
	do $$$AssertEquals(r.trace.%Get(r.trace.%Size() - 1).status, "hum")
	do $$$AssertEquals(r.audit.%Size(), 2)
	set sim = 0
	set it = r.audit.%GetIterator()
	while it.%GetNext(.k, .row) { if $extract(row.detail, *-11, *) = " (simulated)" { set sim = sim + 1 } }
	do $$$AssertEquals(sim, 1, "one audit detail ends (simulated)")
	do $$$AssertEquals(r.precedent, 1)
	do $$$AssertEquals(r.decision.decidedBy, "agent", "approve keeps the original DecidedBy")
}

Method TestApproveTwiceRejected()
{
	set d = ..NewHeld("escalate")
	do ##class(Medic.Actions).Approve(d.%Id())
	try {
		do ##class(Medic.Actions).Approve(d.%Id())
		do $$$AssertFailure("second approve should throw")
	} catch ex {
		do $$$AssertTrue(ex.DisplayString() [ "already decided", "second approve rejected")
	}
}

Method TestAutoAppliedRejected()
{
	set d = ..NewHeld("resend")
	set d.AutoApplied = 1
	do d.%Save()
	try {
		do ##class(Medic.Actions).Approve(d.%Id())
		do $$$AssertFailure("approve of auto-applied should throw")
	} catch ex {
		do $$$AssertTrue(ex.DisplayString() [ "already decided", "auto-applied rejected")
	}
}

Method TestOverrideRerouteNeedsTarget()
{
	set d = ..NewHeld("escalate")
	try {
		do ##class(Medic.Actions).Override(d.%Id(), "reroute")
		do $$$AssertFailure("reroute without a target should throw")
	} catch ex {
		do $$$AssertTrue(ex.DisplayString() [ "reroute needs a target", "needs a target")
	}
	set r = ##class(Medic.Actions).Override(d.%Id(), "reroute", "Medic.To.EPR", "wrong PACS route")
	do $$$AssertEquals(r.decision.action, "reroute")
	do $$$AssertEquals(r.decision.rerouteTarget, "Medic.To.EPR")
	do $$$AssertEquals(r.decision.decidedBy, "human")
	do $$$AssertEquals(r.audit.%Size(), 2)
	try {
		do ##class(Medic.Actions).Override(..NewHeld().%Id(), "bogus")
		do $$$AssertFailure("unknown action should throw")
	} catch ex {
		do $$$AssertTrue(ex.DisplayString() [ "unknown action", "unknown action rejected")
	}
}

Method TestSearchFindsApproved()
{
	set d = ..NewHeld("escalate", "No routing rule matched MSH:5 'EPRR'")
	do ##class(Medic.Actions).Approve(d.%Id())
	set hits = ##class(Medic.Data.Precedent).Search("No routing rule matched MSH:5 'EPR1'")
	do $$$AssertTrue(hits.%Size() >= 1, "got hits")
	do $$$AssertEquals(hits.%Get(0).caseId, d.CaseId, "approved case ranks first")
	do $$$AssertTrue(hits.%Get(0).similarity > 0.5, "similarity > 0.5")
}

Method TestMockUsesPrecedent()
{
	set d = ..NewHeld("escalate", "No routing rule matched MSH:5 'LABB'")
	do ##class(Medic.Actions).Approve(d.%Id())
	set req = ##class(Medic.Msg.FailedMessage).%New()
	set req.CaseId = "UT-mock", req.Format = "hl7v2"
	set req.ErrorText = "No routing rule matched MSH:5 'LABB'"
	do req.RawMessage.Write("MSH|^~\&|LIS|MEDIC_HOSP|LABB|MEDIC_HOSP|20261001120000||ORU^R01^ORU_R01|MSG1|P|2.5"_$char(13))
	set req.ContextJSON = {"routing_table": {"LAB": "Medic.To.LIS"}}.%ToJSON()
	set dec = ##class(Medic.Msg.Decision).%New()
	do $$$AssertStatusOK(##class(Medic.Provider.AgentMock).Decide(req, dec))
	// remove it now so it cannot outrank the precedent TestSearchFindsApproved expects
	set case = d.CaseId
	&sql(DELETE FROM Medic_Data.Precedent WHERE CaseId = :case)
	set found = 0, steps = dec.Steps()
	for i = 0:1:steps.%Size() - 1 {
		if steps.%Get(i).stage = "SearchPrecedents" { set found = 1, val = steps.%Get(i).value }
	}
	do $$$AssertTrue(found, "SearchPrecedents step present")
	do $$$AssertEquals($get(val), "precedent "_d.CaseId, "step names the precedent case")
	do $$$AssertTrue(dec.Rationale [ "Precedent", "rationale cites the precedent")
}

Method TestAuditFailureFailsTheAction()
{
	set bad = ##class(Medic.Data.Audit).Log(1, "x", "a", "e", $justify("", 1001))
	do $$$AssertTrue($$$ISERR(bad), "Log rejects an over-long detail")
	set d = ..NewHeld("escalate")
	try {
		do ##class(Medic.Actions).Approve(d.%Id(), $justify("", 1001))
		do $$$AssertFailure("approve should throw when the audit write fails")
	} catch ex {
		do $$$AssertTrue(1, "audit failure surfaced")
	}
}

}
