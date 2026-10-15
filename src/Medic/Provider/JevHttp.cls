/// Real Jev provider (TypeSafe API or Cloudflare Workers AI model "typesafe/jev").
/// Not implemented yet: endpoint, request schema, pricing and context limit must be confirmed
/// against TypeSafe's docs first. Until then the production uses Medic.Provider.JevMock.
Class Medic.Provider.JevHttp Extends Medic.Provider.Base
{

Parameter PRICEPERMTOKENS = 0.04;

ClassMethod Decide(pReq As Medic.Msg.FailedMessage, pDecision As Medic.Msg.Decision, pHint As Medic.Msg.Decision = "") As %Status
{
	// TODO: one batched typed call - choice(action), score(severity), bool checks - mapped onto pDecision.
	quit $$$ERROR($$$GeneralError, "Medic.Provider.JevHttp is not implemented; set ProviderClass to Medic.Provider.JevMock")
}

}
