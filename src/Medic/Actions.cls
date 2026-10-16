/// What a person can do with a decision held for them: approve it or override it.
/// Each call adds a "hum" trace step, writes audit rows and stores a precedent. Failures throw
/// %Exception.StatusException whose text contains "already decided by a person", "reroute needs a target"
/// or "unknown action".
Class Medic.Actions
{

Parameter ACTIONS = "resend,fix_and_resend,reroute,quarantine,escalate";

ClassMethod Approve(pDecisionId As %Integer, pActor As %String = "demo-user") As %DynamicObject
{
	set d = ..Open(pDecisionId)
	do ..CheckOpen(d)
	set action = d.Action
	do d.AddStep("Person", "hum", "approved "_action, "confirmed by "_pActor)
	$$$ThrowOnError(d.%Save())
	do ##class(Medic.Data.Audit).Log(pDecisionId, d.CaseId, "You", "approved "_action, "confirmed by "_pActor)
	do ##class(Medic.Data.Audit).Log(pDecisionId, d.CaseId, "Production", "action executed", ..Simulated(action))
	quit ..Finish(d, pActor, "approved "_action)
}

ClassMethod Override(pDecisionId As %Integer, pAction As %String, pRerouteTarget As %String = "", pReason As %String = "", pActor As %String = "demo-user") As %DynamicObject
{
	set d = ..Open(pDecisionId)
	do ..CheckOpen(d)
	if '$listfind($listfromstring(..#ACTIONS), pAction) { do ..Throw("unknown action '"_pAction_"'") }
	if pAction = "reroute" {
		if pRerouteTarget = "" { do ..Throw("reroute needs a target") }
		if '..IsRouteTarget(pRerouteTarget) { do ..Throw("reroute needs a target from the MedicRouting table, not '"_pRerouteTarget_"'") }
	}
	set was = d.Action
	set d.Action = pAction
	set d.RerouteTarget = $select(pAction = "reroute": pRerouteTarget, 1: "")
	set d.DecidedBy = "human"
	do d.AddStep("Person", "hum", "overrode → "_pAction, $select(pReason '= "": pReason, 1: "changed by "_pActor)_" (was "_was_")")
	$$$ThrowOnError(d.%Save())
	do ##class(Medic.Data.Audit).Log(pDecisionId, d.CaseId, "You", "overrode → "_pAction, pReason)
	do ##class(Medic.Data.Audit).Log(pDecisionId, d.CaseId, "Eval", "correction recorded", "was "_was_", now "_pAction)
	quit ..Finish(d, pActor, "overrode → "_pAction_$select(pReason '= "": ": "_pReason, 1: ""))
}

/// The decision as JSON, with its trace and audit rows (shared with the REST layer).
ClassMethod DecisionJSON(pDecision As Medic.Msg.Decision) As %DynamicObject
{
	quit {
		"id": (pDecision.%Id()),
		"caseId": (pDecision.CaseId),
		"action": (pDecision.Action),
		"confidence": (+pDecision.Confidence),
		"severity": (+pDecision.Severity),
		"rationale": (pDecision.Rationale),
		"proposedFix": (pDecision.ProposedFix),
		"rerouteTarget": (pDecision.RerouteTarget),
		"decidedBy": (pDecision.DecidedBy),
		"provider": (pDecision.Provider),
		"autoApplied": (pDecision.AutoApplied + 0),
		"latencyMs": (+pDecision.LatencyMs),
		"costUSD": (+pDecision.CostUSD),
		"trace": (pDecision.Steps()),
		"audit": (##class(Medic.Data.Audit).ForDecision(pDecision.%Id()))
	}
}

/// The failed message's error text: from the request in the decision's session, else the decision's rationale.
ClassMethod ErrorTextFor(pDecision As Medic.Msg.Decision) As %String
{
	set id = pDecision.%Id()
	set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT SessionId FROM Ens.MessageHeader WHERE MessageBodyClassName = 'Medic.Msg.Decision' AND MessageBodyId = ?", id)
	if rs.%Next() {
		set req = ##class(%SQL.Statement).%ExecDirect(, "SELECT MessageBodyId FROM Ens.MessageHeader WHERE SessionId = ? AND MessageBodyClassName = 'Medic.Msg.FailedMessage' ORDER BY ID", rs.SessionId)
		while req.%Next() {
			set fm = ##class(Medic.Msg.FailedMessage).%OpenId(req.MessageBodyId)
			if $isobject(fm), fm.CaseId = pDecision.CaseId, fm.ErrorText '= "" { quit }
			set fm = ""
		}
		if $isobject($get(fm)) { quit fm.ErrorText }
	}
	quit pDecision.Rationale
}

ClassMethod Open(pDecisionId As %Integer) As Medic.Msg.Decision [ Private ]
{
	set d = ##class(Medic.Msg.Decision).%OpenId(pDecisionId)
	if '$isobject(d) { do ..Throw("decision "_pDecisionId_" not found") }
	quit d
}

ClassMethod CheckOpen(pDecision As Medic.Msg.Decision) [ Private ]
{
	set held = 'pDecision.AutoApplied
	set it = pDecision.Steps().%GetIterator()
	while it.%GetNext(.k, .step) { if step.status = "hum" { set held = 0 } }
	if 'held { do ..Throw("already decided by a person (or auto-applied)") }
}

ClassMethod IsRouteTarget(pTarget As %String) As %Boolean [ Private ]
{
	set key = ""
	for {
		set key = $order(^Ens.LookupTable("MedicRouting", key))
		quit:key=""
		if $get(^Ens.LookupTable("MedicRouting", key)) = pTarget { quit }
	}
	quit key '= ""
}

ClassMethod Simulated(pAction As %String) As %String [ Private ]
{
	quit $select(pAction = "escalate": "on-call ward paged (simulated)", 1: pAction_" applied (simulated)")
}

/// Store the precedent, then build the response.
ClassMethod Finish(pDecision As Medic.Msg.Decision, pActor As %String, pSummary As %String) As %DynamicObject [ Private ]
{
	set sc = ##class(Medic.Data.Precedent).Store(pDecision, ..ErrorTextFor(pDecision), pSummary, pActor)
	set json = ..DecisionJSON(pDecision)
	quit {"ok": 1, "decision": (json), "trace": (json.trace), "audit": (json.audit), "precedent": ($select($$$ISOK(sc): 1, 1: 0))}
}

ClassMethod Throw(pText As %String) [ Private ]
{
	throw ##class(%Exception.StatusException).CreateFromStatus($$$ERROR($$$GeneralError, pText))
}

}
