/// A decision the policy held for a person, sent to Medic.Review so it also becomes a Workflow task.
Class Medic.Msg.ReviewRequest Extends Ens.Request
{

Property CaseId As %String(MAXLEN = 128);

Property Action As %String(MAXLEN = 32);

Property Confidence As %Numeric(SCALE = 4);

Property Severity As %Numeric(SCALE = 4);

Property Rationale As %String(MAXLEN = 4000);

Property ProposedFix As %String(MAXLEN = "");

Property RerouteTarget As %String(MAXLEN = 128);

ClassMethod From(pDecision As Medic.Msg.Decision) As Medic.Msg.ReviewRequest
{
	set r = ..%New()
	for prop = "CaseId", "Action", "Confidence", "Severity", "Rationale", "ProposedFix", "RerouteTarget" {
		set $property(r, prop) = $property(pDecision, prop)
	}
	quit r
}

}
