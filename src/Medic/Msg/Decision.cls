/// Typed triage decision for one failed message.
Class Medic.Msg.Decision Extends Ens.Response
{

Property CaseId As %String(MAXLEN = 128);

Property Action As %String(VALUELIST = ",resend,fix_and_resend,reroute,quarantine,escalate");

Property Confidence As %Numeric(MAXVAL = 1, MINVAL = 0, SCALE = 4);

/// Patient-safety severity, 0 (cosmetic) to 1 (possible harm).
Property Severity As %Numeric(MAXVAL = 1, MINVAL = 0, SCALE = 4);

Property Rationale As %String(MAXLEN = 4000);

Property ProposedFix As %String(MAXLEN = "");

Property RerouteTarget As %String(MAXLEN = 128);

/// Which tier made the call.
Property DecidedBy As %String(VALUELIST = ",jev,agent,human");

/// Provider class that produced it, so mock results are never mistaken for real model output.
Property Provider As %String(MAXLEN = 128);

/// Set by Medic.Policy.AutoApply; false means it waits for a human.
Property AutoApplied As %Boolean [ InitialExpression = 0 ];

Property LatencyMs As %Integer;

/// Estimated from message length and the provider's configured price, not billed usage.
Property CostUSD As %Numeric(SCALE = 8) [ InitialExpression = 0 ];

/// Copy every decision field from pOther (used by the BPL to fill its own response object;
/// replacing that object instead leaves an empty, header-less Decision row behind).
Method CopyFrom(pOther As Medic.Msg.Decision)
{
	for prop = "CaseId", "Action", "Confidence", "Severity", "Rationale", "ProposedFix", "RerouteTarget", "DecidedBy", "Provider", "AutoApplied", "LatencyMs", "CostUSD" {
		set $property($this, prop) = $property(pOther, prop)
	}
}

}
