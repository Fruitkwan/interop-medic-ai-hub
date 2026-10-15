/// The decision agent. Every failed message comes here, so every decision is the agent's.
/// Step 1 asks the fast tier (Jev, Laya or the mock; visible in the Visual Trace as a call to
/// Medic.FastTier). When it is confident and the case is low-stakes the agent accepts that verdict
/// and stops. Otherwise it runs the full tool-using provider with the fast verdict as a hint.
Class Medic.Operation.Agent Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

Property ProviderClass As %String(MAXLEN = 128) [ InitialExpression = "Medic.Provider.AgentMock" ];

Property FastTarget As Ens.DataType.ConfigName [ InitialExpression = "Medic.FastTier" ];

/// Minimum fast-tier confidence to accept its verdict without running the full agent.
Property FastConfidence As %Numeric [ InitialExpression = 0.85 ];

/// Cases at or above this severity always get the full agent.
Property FastSeverityCeiling As %Numeric [ InitialExpression = 0.6 ];

Parameter SETTINGS = "ProviderClass:Basic,FastTarget:Basic,FastConfidence:Gate,FastSeverityCeiling:Gate";

Method OnMessage(pRequest As Medic.Msg.FailedMessage, Output pResponse As Medic.Msg.Decision) As %Status
{
	set start = $zhorolog
	set sc = ..SendRequestSync(..FastTarget, pRequest, .fast)
	quit:$$$ISERR(sc) sc

	// A reroute needs a target, which only the agent's routing tools can supply.
	if (fast.Confidence >= ..FastConfidence) && (fast.Severity < ..FastSeverityCeiling) && (fast.Action '= "reroute") {
		set pResponse = fast
		quit $$$OK
	}

	set pResponse = ##class(Medic.Msg.Decision).%New()
	set pResponse.CaseId = pRequest.CaseId
	set pResponse.DecidedBy = "agent"
	set sc = $classmethod(..ProviderClass, "Decide", pRequest, pResponse, fast)
	set pResponse.CostUSD = pResponse.CostUSD + fast.CostUSD
	set pResponse.LatencyMs = ($zhorolog - start) * 1000 \ 1
	quit sc
}

}
