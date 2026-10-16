/// The full decision agent: Medic.AIHub.TriageAgent (an AI Hub %AI.Agent with read-only tools)
/// run once per failed message. The AI Hub classes live in src-aihub and are only compiled on an
/// AI Hub build; this provider compiles everywhere and, without AI Hub or on any agent error,
/// escalates with zero confidence instead of failing the message.
Class Medic.Provider.AIHubAgent Extends Medic.Provider.Base
{

Parameter AGENTCLASS = "Medic.AIHub.TriageAgent";

Parameter TRACECLASS = "Medic.AIHub.ToolTrace";

Parameter POLICYCLASS = "Medic.AIHub.ReadOnlyPolicy";

Parameter ACTIONS = ",resend,fix_and_resend,reroute,quarantine,escalate,";

ClassMethod Decide(pReq As Medic.Msg.FailedMessage, pDecision As Medic.Msg.Decision, pHint As Medic.Msg.Decision = "", pConfig As %DynamicObject = "") As %Status
{
	try {
		if '##class(%Dictionary.CompiledClass).%ExistsId(..#AGENTCLASS) {
			$$$ThrowStatus($$$ERROR($$$GeneralError, "AI Hub is not installed in this IRIS image"))
		}
		set agent = $classmethod(..#AGENTCLASS, "%New")
		$$$ThrowOnError(agent.%Init())
		// Policies go on before the session, so tool discovery sees them.
		set trace = $classmethod(..#TRACECLASS, "%New")
		do agent.ToolManager.SetAuthPolicy($classmethod(..#POLICYCLASS, "%New"))
		do agent.ToolManager.SetAuditPolicy(trace)
		// Temperature 0: the same message should get the same decision.
		set session = agent.CreateSession({"temperature": 0})
		set response = agent.Chat(session, ..Prompt(pReq, pHint))
		set it = trace.Calls.%GetIterator()
		while it.%GetNext(, .call) {
			do pDecision.AddStep(call.tool, $select(call.ok: "ok", 1: "bad"), call.summary, call.arguments, call.ms)
		}
		$$$ThrowOnError(..ParseDecision(response.Content, pDecision))
		set tools = trace.Summary()
		set pDecision.Rationale = pDecision.Rationale_$select(tools = "": " [no tools called]", 1: " [tools: "_tools_"]")
		set pDecision.Provider = $classname()_":"_agent.Model
		do pDecision.AddStep("Agent", "ok", pDecision.Action_" "_$fnumber(pDecision.Confidence, "", 2), pDecision.Rationale)
		set pDecision.CostUSD = ..Cost(session.GetStats())
	} catch ex {
		set why = "AI Hub agent unavailable: "_$system.Status.GetOneErrorText(ex.AsStatus())
		do ..Set(pDecision, "escalate", 0, 0.5, why)
		do pDecision.AddStep("Agent", "bad", "unavailable", why)
	}
	quit $$$OK
}

/// The user turn: error first, then context, the fast tier's verdict and the message itself.
ClassMethod Prompt(pReq As Medic.Msg.FailedMessage, pHint As Medic.Msg.Decision = "") As %String
{
	set nl = $char(10)
	set text = "Triage this failed message."_nl_nl_"Error: "_pReq.ErrorText_nl_nl
	if pReq.ContextJSON '= "" set text = text_"Context (JSON): "_pReq.ContextJSON_nl_nl
	if $isobject(pHint) && (pHint.Action '= "") {
		set text = text_"Fast classifier verdict (a hint, not a fact): "_pHint.Action_", confidence "_pHint.Confidence_", severity "_pHint.Severity_". "_pHint.Rationale_nl_nl
	}
	quit text_"Message ("_pReq.Format_"):"_nl_$extract($translate(..Raw(pReq), $char(13), nl), 1, 8000)
}

/// Map the agent's JSON reply onto pDecision. Tolerates prose or code fences around the object.
/// A reroute without a target cannot be applied, so it becomes an escalation.
ClassMethod ParseDecision(pContent As %String, pDecision As Medic.Msg.Decision) As %Status
{
	set start = $find(pContent, "{"), end = $length(pContent)
	while (end > 0) && ($extract(pContent, end) '= "}") { set end = end - 1 }
	if (start = 0) || (end < start) quit $$$ERROR($$$GeneralError, "agent reply has no JSON object: "_$extract(pContent, 1, 200))
	set obj = ""
	try {
		set obj = {}.%FromJSON($extract(pContent, start - 1, end))
	} catch {
		set obj = ""
	}
	quit:'$isobject(obj) $$$ERROR($$$GeneralError, "agent reply is not valid JSON: "_$extract(pContent, 1, 200))
	set action = $zconvert(obj.action, "L")
	if ..#ACTIONS '[ (","_action_",") quit $$$ERROR($$$GeneralError, "agent chose an unknown action: "_obj.action)
	set conf = ..Clamp(obj.confidence), sev = ..Clamp(obj.severity)
	set target = obj."reroute_target", why = obj.rationale
	if (action = "reroute") && (target = "") {
		set action = "escalate", conf = $select(conf < 0.5: conf, 1: 0.5)
		set why = "Agent wanted to reroute but named no target. "_why
	}
	do ..Set(pDecision, action, conf, sev, why, obj."proposed_fix")
	set pDecision.RerouteTarget = $select(action = "reroute": target, 1: "")
	quit $$$OK
}

ClassMethod Clamp(pValue) As %Numeric
{
	set v = +pValue
	quit $select(v < 0: 0, v > 1: 1, 1: v)
}

/// USD from session token stats and AIHUB_PRICE_IN_PER_MTOK / AIHUB_PRICE_OUT_PER_MTOK.
ClassMethod Cost(pStats As %DynamicObject) As %Numeric
{
	quit:'$isobject(pStats) 0
	set in = +$system.Util.GetEnviron("AIHUB_PRICE_IN_PER_MTOK"), out = +$system.Util.GetEnviron("AIHUB_PRICE_OUT_PER_MTOK")
	quit ((+pStats."total_prompt_tokens" * in) + (+pStats."total_completion_tokens" * out)) / 1000000
}

}
