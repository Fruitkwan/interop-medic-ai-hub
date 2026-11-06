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
Property DecidedBy As %String(VALUELIST = ",fast,agent,human");

/// Provider class that produced it, so mock results are never mistaken for real model output.
Property Provider As %String(MAXLEN = 128);

/// Set by Medic.Policy.AutoApply; false means it waits for a human.
Property AutoApplied As %Boolean [ InitialExpression = 0 ];

Property LatencyMs As %Integer;

/// Estimated from message length and the provider's configured price, not billed usage.
Property CostUSD As %Numeric(SCALE = 8) [ InitialExpression = 0 ];

/// JSON array of steps {stage, status, value, detail, ms} that led to this decision; status is ok, warn, bad or hum.
Property TraceJSON As %String(MAXLEN = "");

/// The LLM call behind this decision, shown in the Visual Trace with the message (Community idea
/// DPI-I-689: Interoperability as the tracing tool for LLM pipelines). Blank for the mocks.
Property Model As %String(MAXLEN = 128);

Property InputTokens As %Integer;

Property OutputTokens As %Integer;

/// The user turn sent to the model (the system instructions are in Medic.AIHub.TriageAgent).
Property Prompt As %String(MAXLEN = "");

/// The model's raw reply, before parsing.
Property Completion As %String(MAXLEN = "");

/// JSON array of the agent's tool calls in order: {tool, arguments, summary, ms, ok}.
Property ToolCalls As %String(MAXLEN = "");

/// Append one step to the trace.
Method AddStep(pStage As %String, pStatus As %String, pValue As %String, pDetail As %String = "", pMs As %Integer = 0)
{
	set steps = ..Steps()
	do steps.%Push({"stage": (pStage), "status": (pStatus), "value": (pValue), "detail": (pDetail), "ms": (+pMs)})
	set ..TraceJSON = steps.%ToJSON()
}

/// Add the Policy step from AutoApplied. Held is "warn", never "hum": hum means a person already acted.
Method AddPolicyStep(pThreshold As %Numeric, pDryRun As %Boolean, pMaxSeverity As %Numeric = 0.6)
{
	do ..AddStep("Policy", $select(..AutoApplied: "ok", 1: "warn"), $select(..AutoApplied: "auto-apply", 1: "held for a person"), "threshold "_pThreshold_", severity limit "_pMaxSeverity_$select(pDryRun: ", dry run", 1: ""))
}

/// The trace as a dynamic array (empty when there is none).
Method Steps() As %DynamicArray
{
	quit $select(..TraceJSON = "": [], 1: [].%FromJSON(..TraceJSON))
}

/// Copy every decision field from pOther (used by the BPL to fill its own response object;
/// replacing that object instead leaves an empty, header-less Decision row behind).
Method CopyFrom(pOther As Medic.Msg.Decision)
{
	for prop = "CaseId", "Action", "Confidence", "Severity", "Rationale", "ProposedFix", "RerouteTarget", "DecidedBy", "Provider", "AutoApplied", "LatencyMs", "CostUSD", "TraceJSON",
		"Model", "InputTokens", "OutputTokens", "Prompt", "Completion", "ToolCalls" {
		set $property($this, prop) = $property(pOther, prop)
	}
}

}
