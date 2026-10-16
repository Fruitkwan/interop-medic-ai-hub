/// Read-only tools the triage agent can call. Thin wrappers over Medic.Tools so the same logic
/// serves the agent, the mock and (later) the MCP service.
Class Medic.AIHub.Tools Extends %AI.Tool
{

Parameter DESCRIPTION = "Read-only checks for a failed HL7 v2 or FHIR message in an IRIS Interoperability production.";

/// Parse an HL7 v2 message and check its structure against its message type. Returns JSON:
/// valid (true/false), docType, and the parser's error when invalid.
Method ValidateHL7(message As %String) As %String [ WebMethod ]
{
	quit ##class(Medic.Tools).ValidateHL7($translate(message, $char(10), $char(13)))
}

/// Exact routing lookup: the production item a receiving application (MSH-5) routes to, or empty.
Method GetRoutingRule(receiver As %String) As %String [ WebMethod ]
{
	quit ##class(Medic.Tools).GetRoutingRule(receiver)
}

/// Best-matching known route for a misspelled or variant receiving application name, or empty
/// when nothing is close. Use this before choosing reroute.
Method ClosestRoute(receiver As %String) As %String [ WebMethod ]
{
	quit ##class(Medic.Tools).ClosestRoute(receiver)
}

/// Queue depth of a production item, e.g. Medic.To.EPR. Returns JSON with name and queueDepth.
Method CheckEndpoint(configName As %String) As %String [ WebMethod ]
{
	quit ##class(Medic.Tools).CheckEndpoint(configName)
}

}
