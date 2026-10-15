/// Synchronous entry point for the eval runner. pHint names the target item
/// (Medic.Triage for the full pipeline, Medic.FastTier for the fast tier alone).
Class Medic.Eval.Service Extends Ens.BusinessService
{

Method OnProcessInput(pInput As Medic.Msg.FailedMessage, Output pOutput As Medic.Msg.Decision, ByRef pHint As %String) As %Status
{
	quit ..SendRequestSync($get(pHint, "Medic.Triage"), pInput, .pOutput)
}

}
