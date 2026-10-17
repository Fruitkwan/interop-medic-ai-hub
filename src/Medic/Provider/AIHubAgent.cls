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
		// A configured LLM (a hosted provider from MEDIC_AGENT_MODELS, or a local Ollama model)
		// replaces the AIHUB_* environment defaults. Only a local server (a base URL) may go without a key.
		set cfg = $select($isobject(pConfig): pConfig, 1: {})
		if cfg.provider '= "" {
			if (cfg.apiKey = "") && (cfg.baseUrl = "") {
				$$$ThrowStatus($$$ERROR($$$GeneralError, "no API key configured for provider "_cfg.provider))
			}
			set settings = {"api_key": ($select(cfg.apiKey '= "": cfg.apiKey, 1: "none"))}
			if cfg.baseUrl '= "" set settings."base_url" = cfg.baseUrl
			// AI Hub abandons a request after about 60 s; a local model on a CPU needs longer per round.
			if ..IsOllama(cfg.baseUrl) {
				set secs = +$system.Util.GetEnviron("OLLAMA_TIMEOUT")
				set:secs<=0 secs = 600
				set settings."http_config" = {"request_timeout_secs": (secs), "attempt_timeout_secs": (secs)}
			}
			set agent.Provider = $classmethod("%AI.Provider", "Create", cfg.provider, settings)
			if cfg.model '= "" set agent.Model = cfg.model
			if ..IsOllama(cfg.baseUrl) do ..WarmOllama(cfg.baseUrl, cfg.model, pDecision)
		}
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
			do pDecision.AddStep(call.tool, $select(call.ok: "ok", 1: "bad"), ..ToolValue(call.tool, call.summary), call.summary, call.ms)
		}
		$$$ThrowOnError(..ParseDecision(response.Content, pDecision))
		set tools = trace.Summary()
		set pDecision.Rationale = pDecision.Rationale_$select(tools = "": " [no tools called]", 1: " [tools: "_tools_"]")
		set pDecision.Provider = $classname()_":"_agent.Model
		do pDecision.AddStep("Agent", "ok", pDecision.Action_" "_$fnumber(pDecision.Confidence, "", 2), pDecision.Rationale)
		set pDecision.CostUSD = ..Cost(session.GetStats())
	} catch ex {
		set why = "AI Hub agent unavailable: "_..ErrorText($system.Status.GetOneErrorText(ex.AsStatus()))
		do ..Set(pDecision, "escalate", 0, 0.5, why)
		do pDecision.AddStep("Agent", "bad", "unavailable", why)
	}
	quit $$$OK
}

/// True for a local Ollama server: OLLAMA_BASE_URL or Ollama's port 11434.
ClassMethod IsOllama(pBaseUrl As %String) As %Boolean
{
	set ollama = $system.Util.GetEnviron("OLLAMA_BASE_URL")
	quit (pBaseUrl '= "") && (((ollama '= "") && (pBaseUrl [ ollama)) || (pBaseUrl [ ":11434"))
}

/// Load an Ollama model before the agent uses it. AI Hub abandons an LLM request after about 60 s,
/// and on a CPU-only machine loading the model (often swapping out the fast tier's) takes longer;
/// the abandoned request also cancels the load, so every retry starts over. This call has no such
/// limit and keeps the model loaded for 30 minutes. Failures are left for the agent call to report.
ClassMethod WarmOllama(pBaseUrl As %String, pModel As %String, pDecision As Medic.Msg.Decision)
{
	set start = $zhorolog
	try {
		do ##class(%Net.URLParser).Decompose(pBaseUrl, .url)
		set http = ##class(%Net.HttpRequest).%New()
		set http.Server = url("host"), http.Timeout = 900
		if $get(url("port")) '= "" set http.Port = url("port")
		set http.ContentType = "application/json"
		do http.EntityBody.Write({"model": (pModel), "prompt": "", "keep_alive": "30m"}.%ToJSON())
		set sc = http.Post("/api/generate")
		set ok = $$$ISOK(sc) && (http.HttpResponse.StatusCode = 200)
	} catch {
		set ok = 0
	}
	set ms = ($zhorolog - start) * 1000 \ 1
	do pDecision.AddStep("Load model", $select(ok: "ok", 1: "warn"), pModel, $select(ok: "loaded in Ollama", 1: "could not load in Ollama"), ms)
}

/// One readable line for a provider error. LLM APIs append their whole JSON error body; a quota
/// or rate-limit reply becomes "<provider> quota or rate limit reached (HTTP 429); retry in 14h37m".
ClassMethod ErrorText(pText As %String) As %String
{
	set provider = "", wait = ""
	if $locate(pText, "Provider '[^']+'", 1, , provider) set provider = $piece(provider, "'", 2)
	if (pText [ "HTTP 429") || (pText [ "RESOURCE_EXHAUSTED") || ($zconvert(pText, "L") [ "rate limit") {
		// "retry in 14h37m45.634481496s" -> "retry in 14h37m45s"
		if $locate(pText, "retry in [0-9hm]+(\.[0-9]+)?s?", 1, , wait) {
			set wait = "; "_$piece(wait, ".")_$select((wait [ ".") && ($extract(wait, *) = "s"): "s", 1: "")
		}
		quit $select(provider = "": "LLM", 1: provider)_" quota or rate limit reached (HTTP 429)"_wait
	}
	if pText [ "error sending request" {
		quit $select(provider = "": "LLM", 1: provider)_" request failed or timed out (AI Hub waits about 60 s per request)"
	}
	// Anything else: the text before the JSON body, on one line.
	set text = $piece($piece(pText, "[{", 1), ": {", 1)
	set text = $zstrip($translate(text, $char(10, 13), "  "), "<>=W")
	quit $extract(text, 1, 200)_$select($length(text) > 200: "...", 1: "")
}

/// A short human value for a tool-call trace step, from the tool's raw (escaped, possibly
/// truncated) audit JSON. The raw text stays in the step's detail.
ClassMethod ToolValue(pTool As %String, pSummary As %String) As %String
{
	// The result is JSON inside JSON inside JSON: dropping every backslash leaves the plain
	// "key":value text, which is all the patterns below need.
	set text = $replace(pSummary, "\", ""), val = ""
	if pTool = "SearchPrecedents" {
		if $locate(text, """caseId""\s*:\s*""[^""]+", 1, , val) quit "precedent "_$piece(val, """", 4)
		quit "none"
	}
	if pTool = "ValidateHL7" {
		if $locate(text, """valid""\s*:\s*(true|false)", 1, , val) quit $select(val [ "true": "valid", 1: "invalid")
	}
	if pTool = "CheckEndpoint" {
		if $locate(text, """queueDepth""\s*:\s*""?\d*", 1, , val) quit "queue "_+$translate($piece(val, ":", 2), """ ")
	}
	// Anything else: keep the result part, drop JSON punctuation and a leading "key:".
	if text [ "result_json"":" set text = $piece(text, "result_json"":", 2, *)
	set text = $piece(text, ",""display_text", 1)
	set clean = $zstrip($translate(text, "{}[]"""), "<>W")
	if $locate(clean, "^\w+:", 1, , val) set clean = $zstrip($extract(clean, $length(val) + 1, *), "<W")
	if (pTool = "GetRoutingRule") || (pTool = "ClosestRoute") quit $select(clean = "": "no match", 1: clean)
	quit $extract(clean, 1, 40)
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
