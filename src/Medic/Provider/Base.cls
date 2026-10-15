/// A decision provider. Operations call Decide() via $classmethod on their ProviderClass setting,
/// so mock, HTTP and AI Hub implementations are interchangeable.
Class Medic.Provider.Base [ Abstract ]
{

/// Placeholder USD per million input tokens; subclasses override.
Parameter PRICEPERMTOKENS = 0;

/// Fill pDecision for pReq. pHint is the fast-tier verdict when called from the agent tier;
/// pConfig carries the calling operation's resolved settings (base URL, model, key, price).
ClassMethod Decide(pReq As Medic.Msg.FailedMessage, pDecision As Medic.Msg.Decision, pHint As Medic.Msg.Decision = "", pConfig As %DynamicObject = "") As %Status [ Abstract ]
{
}

ClassMethod Set(pDecision As Medic.Msg.Decision, pAction As %String, pConfidence As %Numeric, pSeverity As %Numeric, pRationale As %String, pFix As %String = "")
{
	set pDecision.Action = pAction, pDecision.Confidence = pConfidence, pDecision.Severity = pSeverity
	set pDecision.Rationale = pRationale, pDecision.ProposedFix = pFix
	set pDecision.Provider = $classname()
}

ClassMethod Raw(pReq As Medic.Msg.FailedMessage) As %String
{
	do pReq.RawMessage.Rewind()
	set raw = pReq.RawMessage.Read(1000000)
	do pReq.RawMessage.Rewind()
	quit raw
}

/// Rough cost: ~4 characters per token over message + error + context.
ClassMethod EstimateCost(pReq As Medic.Msg.FailedMessage) As %Numeric
{
	set chars = pReq.RawMessage.Size + $length(pReq.ErrorText) + $length(pReq.ContextJSON)
	quit (chars / 4) * ..#PRICEPERMTOKENS / 1000000
}

}
