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

Method %LogExecution(call, metadata, result, duration, status)
{
	set name = $select($isobject(call): call.name, 1: "?")
	set args = $select($isobject(call) && $isobject(call.arguments): call.arguments.%ToJSON(), 1: "")
	do ..Calls.%Push({"tool": (name), "arguments": (args), "ms": (+duration), "ok": ($$$ISOK(status))})
}

/// "ClosestRoute, CheckEndpoint" - for the decision rationale.
Method Summary() As %String
{
	set out = "", it = ..Calls.%GetIterator()
	while it.%GetNext(, .c) { set out = out_$select(out = "": "", 1: ", ")_c.tool }
	quit out
}

}
