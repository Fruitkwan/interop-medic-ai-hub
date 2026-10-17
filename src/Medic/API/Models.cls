/// Which model each tier uses, switched at run time by setting host settings on the production items.
/// Fast: Mock | Jev | Laya | the Ollama model (e.g. Nimble v3) | each MEDIC_FAST_MODELS chat model with a key.
/// Agent: Mock | each MEDIC_AGENT_MODELS entry with a key | the Ollama model when OLLAMA_AGENT_MODEL is set.
/// Configured models without a key are listed under "unavailable" with the variable they need.
/// The effective value is the setting, else the env var. Names only: keys stay on the server.
Class Medic.API.Models
{

Parameter FASTITEM = "Medic.FastTier";

Parameter AGENTITEM = "Medic.Agent";

Parameter PRODUCTION = "Medic.Production";

/// Model setting value that means "send no model" (Laya accepts none); a blank setting would fall back to SYSTEMONE_MODEL.
Parameter NOMODEL = "-";

/// {"fast","agent","available":{"fast":[...],"agent":[...]},"unavailable":{"fast":[{"label","need"}],"agent":[...]}}
ClassMethod Get() As %DynamicObject
{
	quit {"fast": (..CurrentFast()), "agent": (..CurrentAgent()),
		"available": {"fast": (..Available("fast")), "agent": (..Available("agent"))},
		"unavailable": {"fast": (..Unavailable("fast")), "agent": (..Unavailable("agent"))}}
}

ClassMethod CurrentFast() As %String
{
	set provider = ##class(Medic.Operation.FastTier).Pick(..HostSetting(..#FASTITEM, "ProviderClass"), "MEDIC_FAST_PROVIDER", "Medic.Provider.JevMock")
	if provider = "Medic.Provider.ChatFast" {
		quit ..Label(..FastModels(), ..HostSetting(..#FASTITEM, "KeyProvider"), ..HostSetting(..#FASTITEM, "Model"))
	}
	quit:(provider '= "Medic.Provider.SystemOne") "Mock"
	set model = ..HostSetting(..#FASTITEM, "Model")
	set url = ##class(Medic.Operation.FastTier).Pick(..HostSetting(..#FASTITEM, "BaseURL"), "SYSTEMONE_BASE_URL")
	quit:((..Ollama() '= "") && (url = ..Ollama())) ..OllamaLabel("fast")
	set laya = $system.Util.GetEnviron("LAYA_BASE_URL")
	quit $select((model = ..#NOMODEL) || ((laya '= "") && (url = laya) && (url '= $system.Util.GetEnviron("SYSTEMONE_BASE_URL"))): "Laya", 1: "Jev")
}

ClassMethod CurrentAgent() As %String
{
	set provider = ##class(Medic.Operation.FastTier).Pick(..HostSetting(..#AGENTITEM, "ProviderClass"), "MEDIC_AGENT_PROVIDER", "Medic.Provider.AgentMock")
	quit:(provider '= "Medic.Provider.AIHubAgent") "Mock"
	quit:((..Ollama() '= "") && (..HostSetting(..#AGENTITEM, "LLMBaseURL") = (..Ollama()_"/v1/"))) ..OllamaLabel("agent")
	set llm = ..HostSetting(..#AGENTITEM, "LLMProvider"), model = ..HostSetting(..#AGENTITEM, "LLMModel")
	// Blank LLM settings mean the AIHUB_* environment.
	if llm = "" set llm = ..Env("AIHUB_PROVIDER", "openai"), model = $system.Util.GetEnviron("AIHUB_MODEL")
	quit ..Label(..AgentModels(), llm, model)
}

/// The label of the entry for this provider and model, else "provider:model".
ClassMethod Label(pModels As %DynamicArray, pProvider As %String, pModel As %String) As %String
{
	set it = pModels.%GetIterator(), found = ""
	while (found = "") && it.%GetNext(, .m) {
		if (m.provider = $zconvert(pProvider, "L")) && (m.model = pModel) set found = m.label
	}
	quit $select(found '= "": found, 1: pProvider_$select(pModel '= "": ":"_pModel, 1: ""))
}

/// The fast tier's chat models (Medic.Provider.ChatFast) from MEDIC_FAST_MODELS, in the same format
/// as MEDIC_AGENT_MODELS. The provider needs an OpenAI-compatible API (see ChatURL).
ClassMethod FastModels() As %DynamicArray
{
	quit ..ParseModels($system.Util.GetEnviron("MEDIC_FAST_MODELS"), ",mock,jev,laya,")
}

/// The OpenAI-compatible base URL for a chat model: <PROVIDER>_BASE_URL, else AI Hub's default for the provider.
ClassMethod ChatURL(pProvider As %String) As %String
{
	set url = ##class(Medic.Operation.Agent).BaseURL(pProvider)
	quit:url'="" url
	set info = ##class(Medic.Operation.Agent).ProviderInfo(pProvider)
	quit $select($isobject(info): info."default_base_url", 1: "")
}

/// Display name of the tier's Ollama model: "nimble-v3" -> "Nimble v3". Blank when not configured;
/// the agent has one only when OLLAMA_AGENT_MODEL is set.
ClassMethod OllamaLabel(pTier As %String) As %String
{
	quit:..Ollama()="" ""
	set model = $select(pTier = "fast": ..Env("OLLAMA_FAST_MODEL", "nimble-v3"), 1: $system.Util.GetEnviron("OLLAMA_AGENT_MODEL"))
	quit:model="" ""
	set t = $translate(model, "-_", "  ")
	quit $zconvert($extract(t), "U")_$extract(t, 2, *)
}

/// Configured models that cannot run yet: [{"label","need"}], shown greyed out on the page.
ClassMethod Unavailable(pTier As %String) As %DynamicArray
{
	set out = []
	quit:((pTier = "agent") && '##class(%Dictionary.CompiledClass).%ExistsId("%AI.Agent")) out
	set list = $select(pTier = "fast": ..FastModels(), 1: ..AgentModels())
	set it = list.%GetIterator()
	while it.%GetNext(, .m) {
		continue:..Usable(pTier, m.provider)
		set name = $translate($zconvert(m.provider, "U"), "-.", "__")
		set known = $isobject(##class(Medic.Operation.Agent).ProviderInfo(m.provider))
		set need = $select(known || (##class(Medic.Operation.Agent).BaseURL(m.provider) '= ""): name_"_API_KEY", 1: name_"_BASE_URL and "_name_"_API_KEY")
		do out.%Push({"label": (m.label), "need": (need)})
	}
	quit out
}

/// A model entry can run: a key on the server and, for the fast tier, an OpenAI-compatible URL.
ClassMethod Usable(pTier As %String, pProvider As %String) As %Boolean
{
	quit:'##class(Medic.Operation.Agent).HasKey(pProvider) 0
	quit $select(pTier = "fast": ..ChatURL(pProvider) '= "", 1: 1)
}

/// The agent's hosted models: MEDIC_AGENT_MODELS, else one entry from AIHUB_PROVIDER and AIHUB_MODEL.
ClassMethod AgentModels() As %DynamicArray
{
	set spec = $system.Util.GetEnviron("MEDIC_AGENT_MODELS")
	if spec = "" set spec = ..Env("AIHUB_PROVIDER", "openai")_":"_$system.Util.GetEnviron("AIHUB_MODEL")
	quit ..ParseModels(spec, ",mock,")
}

/// "Gemini=gemini:gemini-3.5-flash,GPT=openai:gpt-5-mini" -> [{"label","provider","model"}, ...].
/// The label is optional (it defaults from the provider), so is the model (the provider's default).
/// Everything after the first colon is the model, so ids such as "qwen3:8b" survive.
/// Labels in pReserved (",mock," by default) are skipped, and a repeated label keeps its first entry.
ClassMethod ParseModels(pSpec As %String, pReserved As %String = ",mock,") As %DynamicArray
{
	set out = [], seen = pReserved
	for i = 1:1:$length(pSpec, ",") {
		set item = $zstrip($piece(pSpec, ",", i), "<>W")
		continue:item=""
		set label = "", ref = item
		if item [ "=" set label = $zstrip($piece(item, "="), "<>W"), ref = $piece(item, "=", 2, *)
		set provider = $zconvert($zstrip($piece(ref, ":"), "<>W"), "L"), model = $zstrip($piece(ref, ":", 2, *), "<>W")
		continue:provider=""
		if label = "" set label = ..Nice(provider)
		continue:(seen [ (","_$zconvert(label, "L")_","))
		set seen = seen_$zconvert(label, "L")_","
		do out.%Push({"label": (label), "provider": (provider), "model": (model)})
	}
	quit out
}

/// A display name for a provider given without a label.
ClassMethod Nice(pProvider As %String) As %String
{
	set p = $zconvert(pProvider, "L")
	quit $case(p, "openai": "GPT", "anthropic": "Claude", "gemini": "Gemini", "xai": "Grok", "grok": "Grok", : $zconvert($extract(p), "U")_$extract(p, 2, *))
}

/// The model entry with this label, or "".
ClassMethod Entry(pModels As %DynamicArray, pLabel As %String) As %DynamicObject
{
	set it = pModels.%GetIterator(), found = ""
	while (found = "") && it.%GetNext(, .m) { if m.label = pLabel set found = m }
	quit found
}

/// OLLAMA_BASE_URL as the container reaches it, e.g. http://host.docker.internal:11434; blank hides the Ollama choices.
ClassMethod Ollama() As %String
{
	set url = $system.Util.GetEnviron("OLLAMA_BASE_URL")
	quit $select($extract(url, *) = "/": $extract(url, 1, *-1), 1: url)
}

/// Environment value or a default.
ClassMethod Env(pName As %String, pDefault As %String = "") As %String
{
	set v = $system.Util.GetEnviron(pName)
	quit $select(v '= "": v, 1: pDefault)
}

ClassMethod Available(pTier As %String) As %DynamicArray
{
	set out = ["Mock"]
	if pTier = "fast" {
		if ($system.Util.GetEnviron("SYSTEMONE_API_KEY") '= "") && ($system.Util.GetEnviron("SYSTEMONE_BASE_URL") '= "") do out.%Push("Jev")
		if $system.Util.GetEnviron("LAYA_BASE_URL") '= "" do out.%Push("Laya")
		if ..OllamaLabel("fast") '= "" do out.%Push(..OllamaLabel("fast"))
		set it = ..FastModels().%GetIterator()
		while it.%GetNext(, .m) { if ..Usable("fast", m.provider) do out.%Push(m.label) }
	} else {
		set aihub = ##class(%Dictionary.CompiledClass).%ExistsId("%AI.Agent")
		if aihub {
			set it = ..AgentModels().%GetIterator()
			while it.%GetNext(, .m) { if ..Usable("agent", m.provider) do out.%Push(m.label) }
			if ..OllamaLabel("agent") '= "" do out.%Push(..OllamaLabel("agent"))
		}
	}
	quit out
}

/// Switch models: validates the names, sets the host settings, applies them to the running production.
/// Throws %Exception.StatusException with "unknown model" or "not available" in the text.
ClassMethod Set(pFast As %String, pAgent As %String) As %DynamicObject
{
	if '..Has(..Available("fast"), pFast) do ..Fail(pFast, "fast")
	if '..Has(..Available("agent"), pAgent) do ..Fail(pAgent, "agent")

	kill fast, agent
	// Local models on a CPU can take minutes per call; hosted ones get the usual 10 s.
	set fast("TimeoutSeconds") = 10, fast("KeyProvider") = "", fast("Stage") = ""
	if pFast = "Jev" {
		set fast("ProviderClass") = "Medic.Provider.SystemOne"
		set fast("BaseURL") = $system.Util.GetEnviron("SYSTEMONE_BASE_URL"), fast("Model") = $system.Util.GetEnviron("SYSTEMONE_MODEL")
	} elseif pFast = "Laya" {
		set fast("ProviderClass") = "Medic.Provider.SystemOne"
		set fast("BaseURL") = $system.Util.GetEnviron("LAYA_BASE_URL"), fast("Model") = ..#NOMODEL
	} elseif pFast = ..OllamaLabel("fast") {
		set fast("ProviderClass") = "Medic.Provider.SystemOne", fast("Stage") = pFast
		set fast("BaseURL") = ..Ollama(), fast("Model") = ..Env("OLLAMA_FAST_MODEL", "nimble-v3")
		set fast("TimeoutSeconds") = +..Env("OLLAMA_TIMEOUT", 600)
	} elseif pFast '= "Mock" {
		// A chat model: the operation reads the key itself (KeyProvider), as the agent does.
		set m = ..Entry(..FastModels(), pFast)
		set fast("ProviderClass") = "Medic.Provider.ChatFast", fast("Stage") = pFast
		set fast("BaseURL") = ..ChatURL(m.provider), fast("Model") = m.model, fast("KeyProvider") = m.provider
		set fast("TimeoutSeconds") = 30
	} else {
		set fast("ProviderClass") = "Medic.Provider.JevMock", fast("BaseURL") = "", fast("Model") = ""
	}
	set agent("ProviderClass") = $select(pAgent = "Mock": "Medic.Provider.AgentMock", 1: "Medic.Provider.AIHubAgent")
	set agent("LLMProvider") = "", agent("LLMModel") = "", agent("LLMBaseURL") = "", agent("LLMCredentials") = ""
	if pAgent = ..OllamaLabel("agent") {
		// Ollama speaks the OpenAI API under /v1 and needs no key.
		set agent("LLMProvider") = "openai", agent("LLMModel") = $system.Util.GetEnviron("OLLAMA_AGENT_MODEL")
		set agent("LLMBaseURL") = ..Ollama()_"/v1/"
	} elseif pAgent '= "Mock" {
		// Only the provider, the model and the name of the credentials go in the settings;
		// the operation reads the key itself (Medic.Operation.Agent.APIKey).
		set m = ..Entry(..AgentModels(), pAgent)
		set agent("LLMProvider") = m.provider, agent("LLMModel") = m.model
		set agent("LLMBaseURL") = ##class(Medic.Operation.Agent).BaseURL(m.provider)
		set agent("LLMCredentials") = ##class(Medic.Operation.Agent).Credential(m.provider)
	}

	if (pFast '= ..CurrentFast()) || (pAgent '= ..CurrentAgent()) {
		$$$ThrowOnError(..Apply(.fast, .agent))
	}
	quit ..Get()
}

ClassMethod Apply(ByRef pFast, ByRef pAgent) As %Status [ Private ]
{
	set prod = ##class(Ens.Config.Production).%OpenId(..#PRODUCTION)
	if '$isobject(prod) quit $$$ERROR($$$GeneralError, "production "_..#PRODUCTION_" not found")
	do ..SetItem(prod, ..#FASTITEM, .pFast)
	do ..SetItem(prod, ..#AGENTITEM, .pAgent)
	set sc = prod.%Save()
	quit:$$$ISERR(sc) sc
	// UpdateProduction logs to the current device, which would end up in the HTTP response.
	set io = $io, null = $select($zversion [ "Windows": "//./nul", 1: "/dev/null")
	open null:"WNS"
	use null
	set sc = ##class(Ens.Director).UpdateProduction()
	use io
	close null
	quit sc
}

/// Set (or add) Host settings on one production item.
ClassMethod SetItem(pProd As Ens.Config.Production, pItemName As %String, ByRef pValues) [ Private ]
{
	set item = ""
	for i = 1:1:pProd.Items.Count() {
		if pProd.Items.GetAt(i).Name = pItemName set item = pProd.Items.GetAt(i) quit
	}
	if '$isobject(item) do ..Throw("production item "_pItemName_" not found")
	set name = ""
	for {
		set name = $order(pValues(name), 1, value)
		quit:name=""
		set found = 0
		for j = 1:1:item.Settings.Count() {
			set setting = item.Settings.GetAt(j)
			if (setting.Name = name) && (setting.Target = "Host") set setting.Value = value, found = 1 quit
		}
		if 'found {
			set setting = ##class(Ens.Config.Setting).%New()
			set setting.Name = name, setting.Target = "Host", setting.Value = value
			do item.Settings.Insert(setting)
		}
	}
}

ClassMethod HostSetting(pItem As %String, pName As %String) As %String [ Private ]
{
	set value = ##class(Ens.Director).GetHostSettingValue(pItem, pName)
	quit $get(value)
}

ClassMethod Has(pList As %DynamicArray, pValue As %String) As %Boolean [ Private ]
{
	set it = pList.%GetIterator()
	while it.%GetNext(.k, .v) { if v = pValue quit }
	quit $get(v) = pValue
}

ClassMethod Fail(pValue As %String, pTier As %String) [ Private ]
{
	do ..Throw("unknown model '"_pValue_"' (not available) for the "_pTier_" tier")
}

ClassMethod Throw(pText As %String) [ Private ]
{
	throw ##class(%Exception.StatusException).CreateFromStatus($$$ERROR($$$GeneralError, pText))
}

}
