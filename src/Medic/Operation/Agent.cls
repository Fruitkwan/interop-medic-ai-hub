/// The decision agent. Every failed message comes here, so every decision is the agent's.
/// Step 1 asks the fast tier (Jev, Laya or the mock; visible in the Visual Trace as a call to
/// Medic.FastTier). When it is confident and the case is low-stakes the agent accepts that verdict
/// and stops. Otherwise it runs the full tool-using provider with the fast verdict as a hint.
Class Medic.Operation.Agent Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

/// Blank means MEDIC_AGENT_PROVIDER, else Medic.Provider.AgentMock. The real agent is
/// Medic.Provider.AIHubAgent (needs the AI Hub build and an LLM key).
Property ProviderClass As %String(MAXLEN = 128);

Property FastTarget As Ens.DataType.ConfigName [ InitialExpression = "Medic.FastTier" ];

/// Minimum fast-tier confidence to accept its verdict without running the full agent.
Property FastConfidence As %Numeric [ InitialExpression = 0.85 ];

/// Cases at or above this severity always get the full agent.
Property FastSeverityCeiling As %Numeric [ InitialExpression = 0.6 ];

/// AI Hub provider name (openai, anthropic, gemini, xai, ...). Blank means AIHUB_PROVIDER.
/// Set with LLMBaseURL for an OpenAI-compatible local server such as Ollama.
Property LLMProvider As %String(MAXLEN = 64);

/// Model id, e.g. gemma4. Blank means AIHUB_MODEL.
Property LLMModel As %String(MAXLEN = 128);

/// Base URL for the provider, e.g. http://host.docker.internal:11434/v1/ for Ollama. Blank means the provider's default.
Property LLMBaseURL As %String(MAXLEN = 512);

/// Interoperability credentials whose Password is the provider's API key. Blank means the
/// environment (see APIKey). Keys never go in host settings or come from the web page.
Property LLMCredentials As %String(MAXLEN = 128);

Parameter SETTINGS = "ProviderClass:Basic,FastTarget:Basic,FastConfidence:Gate,FastSeverityCeiling:Gate,LLMProvider:LLM,LLMModel:LLM,LLMBaseURL:LLM,LLMCredentials:LLM:credentialsSelector";

/// LLM settings handed to Decide(); empty when the AIHUB_* environment defaults apply.
Property Config As %DynamicObject [ Transient ];

Method OnInit() As %Status
{
	set ..ProviderClass = ##class(Medic.Operation.FastTier).Pick(..ProviderClass, "MEDIC_AGENT_PROVIDER", "Medic.Provider.AgentMock")
	set ..Config = {}
	if ..LLMProvider '= "" {
		set ..Config = {"provider": (..LLMProvider), "model": (..LLMModel), "baseUrl": (..LLMBaseURL)}
		set key = ..APIKey(..LLMProvider, ..LLMCredentials)
		if key '= "" set ..Config.apiKey = key
	}
	$$$LOGINFO("Agent provider "_..ProviderClass_$select(..LLMProvider '= "": " ("_..LLMProvider_" "_..LLMModel_")", 1: ""))
	quit $$$OK
}

Method OnMessage(pRequest As Medic.Msg.FailedMessage, Output pResponse As Medic.Msg.Decision) As %Status
{
	set start = $zhorolog
	set sc = ..SendRequestSync(..FastTarget, pRequest, .fast)
	quit:$$$ISERR(sc) sc

	// A reroute needs a target, which only the agent's routing tools can supply.
	set conf = $fnumber(fast.Confidence, "", 2), sev = $fnumber(fast.Severity, "", 2)
	if fast.Action = "reroute" {
		set reason = "reroute needs a target"
	} elseif fast.Confidence < ..FastConfidence {
		set reason = "confidence "_conf_" < "_..FastConfidence
	} elseif fast.Severity >= ..FastSeverityCeiling {
		set reason = "severity "_sev_" "_$char(8805)_" "_..FastSeverityCeiling
	} else {
		set reason = ""
	}
	if reason = "" {
		do fast.AddStep("Gate", "ok", "trusted", "confidence "_conf_" "_$char(8805)_" "_..FastConfidence_", severity "_sev_" < "_..FastSeverityCeiling)
		set pResponse = fast
		quit $$$OK
	}

	set pResponse = ##class(Medic.Msg.Decision).%New()
	set pResponse.CaseId = pRequest.CaseId
	set pResponse.DecidedBy = "agent"
	set pResponse.TraceJSON = fast.TraceJSON
	do pResponse.AddStep("Gate", "warn", "to agent", reason)
	set sc = $classmethod(..ProviderClass, "Decide", pRequest, pResponse, fast, ..Config)
	set pResponse.CostUSD = pResponse.CostUSD + fast.CostUSD
	set pResponse.LatencyMs = ($zhorolog - start) * 1000 \ 1
	quit sc
}

/// The API key for an AI Hub provider, read on the server only: the Password of pCredentials, else
/// <PROVIDER>_API_KEY (GEMINI_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY, XAI_API_KEY, ...), else the
/// variable AI Hub names for the provider (GOOGLE_API_KEY for gemini), else AIHUB_API_KEY when
/// pProvider is AIHUB_PROVIDER.
ClassMethod APIKey(pProvider As %String, pCredentials As %String = "") As %String
{
	set key = ""
	if pCredentials '= "" set key = ##class(Ens.Config.Credentials).GetValue(pCredentials, "Password")
	quit:key'="" key
	set name = $zconvert(pProvider, "U")
	set key = $system.Util.GetEnviron($translate(name, "-.", "__")_"_API_KEY")
	quit:key'="" key
	set info = ..ProviderInfo(pProvider)
	if $isobject(info) && $isobject(info.config) {
		set it = info.config.%GetIterator()
		while it.%GetNext(, .item) {
			if (item.name = "api_key") && (item."env_var" '= "") set key = $system.Util.GetEnviron(item."env_var") quit
		}
	}
	quit:key'="" key
	set aihub = $system.Util.GetEnviron("AIHUB_PROVIDER")
	if $zconvert($select(aihub '= "": aihub, 1: "openai"), "U") = name set key = $system.Util.GetEnviron("AIHUB_API_KEY")
	quit key
}

/// "Medic.<provider>" when those Interoperability credentials exist and hold a key, else blank.
ClassMethod Credential(pProvider As %String) As %String
{
	set id = "Medic."_$zconvert(pProvider, "L")
	quit:'##class(Ens.Config.Credentials).%ExistsId(id) ""
	quit $select(##class(Ens.Config.Credentials).GetValue(id, "Password") '= "": id, 1: "")
}

/// True when AI Hub knows the provider and a key for it is configured on the server.
ClassMethod HasKey(pProvider As %String) As %Boolean
{
	quit:'$isobject(..ProviderInfo(pProvider)) 0
	quit ..APIKey(pProvider, ..Credential(pProvider)) '= ""
}

/// The provider's entry from %AI.Provider.%GetProviders() (by name or alias), or "" without AI Hub.
ClassMethod ProviderInfo(pProvider As %String) As %DynamicObject
{
	quit:'##class(%Dictionary.CompiledClass).%ExistsId("%AI.Provider") ""
	set want = $zconvert(pProvider, "L"), found = ""
	try {
		set list = $classmethod("%AI.Provider", "%GetProviders")
		set it = list.%GetIterator()
		while (found = "") && it.%GetNext(, .p) {
			if $zconvert(p.name, "L") = want set found = p quit
			set al = p.aliases.%GetIterator()
			while al.%GetNext(, .a) { if $zconvert(a, "L") = want set found = p quit }
		}
	} catch {
		set found = ""
	}
	quit found
}

}
