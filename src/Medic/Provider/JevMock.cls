/// Offline stand-in for Jev. Keyword rules over the error text with fixed confidences.
/// Deliberately context-blind, like a fast classifier, so the agent tier has real work to do
/// (it cannot tell a routine timeout from a critical result stuck behind a long outage).
Class Medic.Provider.JevMock Extends Medic.Provider.Base
{

/// Placeholder until Jev pricing is confirmed from TypeSafe's docs.
Parameter PRICEPERMTOKENS = 0.04;

ClassMethod Decide(pReq As Medic.Msg.FailedMessage, pDecision As Medic.Msg.Decision, pHint As Medic.Msg.Decision = "") As %Status
{
	set err = $zconvert(pReq.ErrorText, "L")
	set raw = ..Raw(pReq)
	set critical = (raw [ "|HH|") || (raw [ "|LL|")

	if err [ "duplicate" {
		do ..Set(pDecision, "quarantine", 0.95, 0.1, "Message control ID already processed")
	} elseif err [ "mpi mismatch" {
		do ..Set(pDecision, "escalate", 0.6, 0.9, "Patient identity conflict")
	} elseif (err [ "timed out") || (err [ "refused") || (err ? 1"http 5"2N.E) {
		do ..Set(pDecision, "resend", 0.88, $select(critical: 0.9, 1: 0.3), "Transport failure; message itself looks valid")
	} elseif (err [ "no routing rule") || (err [ "no target") {
		do ..Set(pDecision, "reroute", 0.7, 0.4, "Receiving application not in routing table")
	} elseif (err [ "invalid ts") || (err [ "pid field 7") {
		// Slash dates may be dd/mm vs mm/dd; a fast classifier should be less sure about those.
		do ..Set(pDecision, "fix_and_resend", $select(err [ "/": 0.75, 1: 0.86), 0.2, "Birth date in wrong format")
	} elseif err [ "table 0004" {
		do ..Set(pDecision, "fix_and_resend", 0.87, 0.25, "Non-standard patient class code")
	} elseif err [ "unexpectedsegment" {
		do ..Set(pDecision, "fix_and_resend", 0.85, 0.2, "Segments out of order")
	} elseif (err [ "pid:3") || (err [ "pid-3") {
		do ..Set(pDecision, "escalate", 0.9, 0.7, "No patient identifier")
	} elseif (err [ "unexpected end") || (err [ "malformed") {
		do ..Set(pDecision, "quarantine", 0.8, 0.5, "Message is truncated or malformed")
	} elseif err [ "unknown resourcetype" {
		do ..Set(pDecision, "fix_and_resend", 0.9, 0.15, "Wrong resourceType casing")
	} elseif err [ "birthdate" {
		do ..Set(pDecision, "fix_and_resend", 0.88, 0.2, "FHIR date not in YYYY-MM-DD")
	} elseif err [ "subject is required" {
		do ..Set(pDecision, "escalate", 0.85, 0.8, "Result has no patient reference")
	} else {
		do ..Set(pDecision, "escalate", 0.3, 0.5, "Unrecognised failure")
	}
	set pDecision.CostUSD = ..EstimateCost(pReq)
	quit $$$OK
}

}
