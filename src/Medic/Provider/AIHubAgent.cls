/// Real decision agent built on AI Hub (%AI.Agent with a %AI.ToolSet over Medic.Tools).
/// Not implemented yet: the Early Access SDK API must be checked against ai-hub-dev-template
/// before writing this. Until then the production uses Medic.Provider.AgentMock.
Class Medic.Provider.AIHubAgent Extends Medic.Provider.Base
{

ClassMethod Decide(pReq As Medic.Msg.FailedMessage, pDecision As Medic.Msg.Decision, pHint As Medic.Msg.Decision = "", pConfig As %DynamicObject = "") As %Status
{
	// TODO: run the agent with tools ValidateHL7, GetRoutingRule, CheckEndpoint, ClosestRoute, JevTriage;
	// require structured output matching Medic.Msg.Decision; pass pHint as the fast-tier verdict.
	quit $$$ERROR($$$GeneralError, "Medic.Provider.AIHubAgent is not implemented; set ProviderClass to Medic.Provider.AgentMock")
}

}
