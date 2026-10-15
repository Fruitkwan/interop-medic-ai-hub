/// Offline stand-in for the AI Hub agent. Uses the same tools the real agent will call
/// (routing table, endpoint health, message content) to resolve cases the fast tier cannot.
Class Medic.Provider.AgentMock Extends Medic.Provider.Base
{

/// Placeholder for a frontier-model agent run.
Parameter PRICEPERMTOKENS = 3;

ClassMethod Decide(pReq As Medic.Msg.FailedMessage, pDecision As Medic.Msg.Decision, pHint As Medic.Msg.Decision = "") As %Status
{
	set sc = $$$OK
	try {
		set ctx = $select(pReq.ContextJSON = "": {}, 1: {}.%FromJSON(pReq.ContextJSON))
		set err = $zconvert(pReq.ErrorText, "L")
		set raw = ..Raw(pReq)
		set critical = (raw [ "|HH|") || (raw [ "|LL|")
		set downMin = $select($isobject(ctx.endpoint): +ctx.endpoint."down_minutes", 1: 0)

		if (err [ "timed out") || (err [ "refused") || (err ? 1"http 5"2N.E) {
			if critical && (downMin >= 120) {
				do ..Set(pDecision, "escalate", 0.92, 0.95,
					"Critical result undelivered for "_downMin_" minutes; a clinician must be told now",
					"Phone the ward with the result; resend when "_ctx.endpoint.name_" recovers")
			} else {
				do ..Set(pDecision, "resend", 0.9, $select(critical: 0.6, 1: 0.3),
					"Transient transport failure ("_downMin_" min); message is valid", "Resend unchanged")
			}
		} elseif (err [ "no routing rule") || (err [ "no target") {
			set bad = $piece(pReq.ErrorText, "'", 2)
			set target = ##class(Medic.Tools).ClosestRoute(bad, ctx."routing_table")
			if target = "" {
				do ..Set(pDecision, "escalate", 0.6, 0.4, "Receiver '"_bad_"' matches no known route")
			} else {
				do ..Set(pDecision, "reroute", 0.9, 0.4, "Receiver '"_bad_"' is a variant of a known route", "Send to "_target)
				set pDecision.RerouteTarget = target
			}
		} elseif (err [ "invalid ts") || (err [ "pid field 7") {
			set v = $piece(pReq.ErrorText, "'", 2)
			set a = +$extract(v, 1, 2), b = +$extract(v, 4, 5)
			if (v ? 2N1"/"2N1"/"4N) && (a <= 12) && (b <= 12) && (a '= b) {
				do ..Set(pDecision, "escalate", 0.85, 0.5,
					"Birth date '"_v_"' is ambiguous (day/month order); guessing risks a wrong-patient match",
					"Confirm DOB with the source system")
			} else {
				do ..Set(pDecision, "fix_and_resend", 0.9, 0.2, "Birth date in a non-HL7 format",
					"Set PID-7 to "_$translate(v, "/-", ""))
			}
		} elseif $isobject(pHint) {
			do ..Set(pDecision, pHint.Action, pHint.Confidence, pHint.Severity, "Agent concurs with fast pass: "_pHint.Rationale)
		} else {
			do ..Set(pDecision, "escalate", 0.3, 0.5, "No rule applies; needs a person")
		}
		set pDecision.CostUSD = ..EstimateCost(pReq)
	} catch ex {
		set sc = ex.AsStatus()
	}
	quit sc
}

}
