/// Records every tool call the agent makes, so the decision can say which checks it ran and the
/// Interoperability event log shows them next to the message.
Class Medic.AIHub.ToolTrace Extends %AI.Policy.Audit
{

Property Calls As %DynamicArray;

Method %OnNew() As %Status
{
	set ..Calls = []
	quit $$$OK
}

/// Build 154 requires these exact argument types and a %Status return (the EAP docs show neither).
Method %LogExecution(call As %DynamicObject, metadata As %DynamicObject, result As %DynamicObject, duration As %Integer, status As %Status) As %Status
{
	set call = $get(call), result = $get(result), status = $get(status, 1)
	set name = $select($isobject(call): call.name, 1: "?")
	// Build 154 passes the arguments as a JSON string, not an object.
	set args = ""
	if $isobject(call) set args = $select($isobject(call.arguments): call.arguments.%ToJSON(), 1: call.arguments)
	set summary = $extract($select($isobject(result): result.%ToJSON(), 1: result), 1, 1000)
	do ..Calls.%Push({"tool": (name), "arguments": (args), "summary": (summary), "ms": (+$get(duration)), "ok": ($$$ISOK(status))})
	quit $$$OK
}

/// "ClosestRoute, CheckEndpoint" - for the decision rationale.
Method Summary() As %String
{
	set out = "", it = ..Calls.%GetIterator()
	while it.%GetNext(, .c) { set out = out_$select(out = "": "", 1: ", ")_c.tool }
	quit out
}

}
