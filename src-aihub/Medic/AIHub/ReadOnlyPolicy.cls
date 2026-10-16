/// The agent may read freely but never act: only the listed read-only tools may run.
/// Anything that would change data (resend, reroute, edit) is applied by the production after
/// Medic.Policy.AutoApply or a person approves it, never by the agent itself.
Class Medic.AIHub.ReadOnlyPolicy Extends %AI.Policy.Authorization
{

Parameter ALLOWED = ",ValidateHL7,GetRoutingRule,ClosestRoute,CheckEndpoint,";

/// toolref identifies the registration (e.g. "iris:Medic.AIHub.ToolSet"), not the tool;
/// the tool being called is call.name.
Method %CanExecute(toolref As %String, call As %DynamicObject, metadata As %DynamicObject) As %Status
{
	set name = $select($isobject(call): call.name, 1: "")
	// Defensive: strip any registration prefix ("Class.Tool" or "ns:Tool").
	set name = $piece($piece(name, ":", *), ".", *)
	quit:..#ALLOWED[(","_name_",") $$$OK
	quit $$$ERROR($$$GeneralError, "Tool "_name_" ("_toolref_") is not on the read-only allow list")
}

}
