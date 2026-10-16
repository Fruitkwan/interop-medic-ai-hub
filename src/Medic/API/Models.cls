/// Which model each tier uses, switched at run time by setting host settings on the production items.
/// Fast: Mock | Jev | Laya.  Agent: Mock | Gemini.  The effective value is the setting, else the env var.
Class Medic.API.Models
{

Parameter FASTITEM = "Medic.FastTier";

Parameter AGENTITEM = "Medic.Agent";

Parameter PRODUCTION = "Medic.Production";

/// Model setting value that means "send no model" (Laya accepts none); a blank setting would fall back to SYSTEMONE_MODEL.
Parameter NOMODEL = "-";

/// {"fast","agent","available":{"fast":[...],"agent":[...]}}
ClassMethod Get() As %DynamicObject
{
	quit {"fast": (..CurrentFast()), "agent": (..CurrentAgent()), "available": {"fast": (..Available("fast")), "agent": (..Available("agent"))}}
}

ClassMethod CurrentFast() As %String
{
	set provider = ##class(Medic.Operation.FastTier).Pick(..HostSetting(..#FASTITEM, "ProviderClass"), "MEDIC_FAST_PROVIDER", "Medic.Provider.JevMock")
	quit:(provider '= "Medic.Provider.SystemOne") "Mock"
	set model = ..HostSetting(..#FASTITEM, "Model")
	set url = ##class(Medic.Operation.FastTier).Pick(..HostSetting(..#FASTITEM, "BaseURL"), "SYSTEMONE_BASE_URL")
	set laya = $system.Util.GetEnviron("LAYA_BASE_URL")
	quit $select((model = ..#NOMODEL) || ((laya '= "") && (url = laya) && (url '= $system.Util.GetEnviron("SYSTEMONE_BASE_URL"))): "Laya", 1: "Jev")
}

ClassMethod CurrentAgent() As %String
{
	set provider = ##class(Medic.Operation.FastTier).Pick(..HostSetting(..#AGENTITEM, "ProviderClass"), "MEDIC_AGENT_PROVIDER", "Medic.Provider.AgentMock")
	quit $select(provider = "Medic.Provider.AIHubAgent": "Gemini", 1: "Mock")
}

ClassMethod Available(pTier As %String) As %DynamicArray
{
	set out = ["Mock"]
	if pTier = "fast" {
		if ($system.Util.GetEnviron("SYSTEMONE_API_KEY") '= "") && ($system.Util.GetEnviron("SYSTEMONE_BASE_URL") '= "") do out.%Push("Jev")
		if $system.Util.GetEnviron("LAYA_BASE_URL") '= "" do out.%Push("Laya")
	} else {
		if ($system.Util.GetEnviron("AIHUB_API_KEY") '= "") && ##class(%Dictionary.CompiledClass).%ExistsId("%AI.Agent") do out.%Push("Gemini")
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
	if pFast = "Jev" {
		set fast("ProviderClass") = "Medic.Provider.SystemOne"
		set fast("BaseURL") = $system.Util.GetEnviron("SYSTEMONE_BASE_URL"), fast("Model") = $system.Util.GetEnviron("SYSTEMONE_MODEL")
	} elseif pFast = "Laya" {
		set fast("ProviderClass") = "Medic.Provider.SystemOne"
		set fast("BaseURL") = $system.Util.GetEnviron("LAYA_BASE_URL"), fast("Model") = ..#NOMODEL
	} else {
		set fast("ProviderClass") = "Medic.Provider.JevMock", fast("BaseURL") = "", fast("Model") = ""
	}
	set agent("ProviderClass") = $select(pAgent = "Gemini": "Medic.Provider.AIHubAgent", 1: "Medic.Provider.AgentMock")

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
