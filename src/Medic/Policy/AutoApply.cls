/// Decides whether a decision may be applied without a human. Thresholds will come from the
/// eval harness calibration; until then they are production settings on Medic.Triage.
/// Confidence alone is not enough: a model can be sure and wrong, so a severe case always waits.
Class Medic.Policy.AutoApply
{

ClassMethod CanAutoApply(pDecision As Medic.Msg.Decision, pThreshold As %Numeric, pDryRun As %Boolean, pMaxSeverity As %Numeric = 0.6) As %Boolean
{
	quit:pDryRun 0
	quit:'$isobject(pDecision) 0
	quit:pDecision.Action="escalate" 0
	quit:(pDecision.Severity >= pMaxSeverity) 0
	quit (pDecision.Confidence >= pThreshold)
}

}
