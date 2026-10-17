/// System 1: one fast typed call per failed message.
/// The provider is chosen by the ProviderClass setting, else the MEDIC_FAST_PROVIDER environment
/// variable, else the offline mock. SystemOne settings work the same way (setting, then env var),
/// so the same build can run Jev (hosted), Laya (hosted or local) or the mock.
Class Medic.Operation.FastTier Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

/// Blank means MEDIC_FAST_PROVIDER, else Medic.Provider.JevMock.
Property ProviderClass As %String(MAXLEN = 128);

/// SystemOne base URL, e.g. http://host.docker.internal:8000 for laya-serve. Blank means SYSTEMONE_BASE_URL.
Property BaseURL As %String(MAXLEN = 512);

/// Optional checkpoint or model id (Laya: english, multilingual, typed-decisions). Blank means SYSTEMONE_MODEL; "-" sends none.
Property Model As %String(MAXLEN = 128);

/// Interoperability credentials whose password is the API key. Blank means SYSTEMONE_API_KEY.
Property Credentials As %String(MAXLEN = 128);

Property TimeoutSeconds As %Integer [ InitialExpression = 10 ];

/// USD per million input tokens, for cost tracking (Jev: 0.042 per laya-ai.com; self-hosted: 0).
/// Blank means SYSTEMONE_PRICE_PER_MTOK, else 0.
Property PricePerMTokens As %String;

/// For Medic.Provider.ChatFast: the provider whose key to use (inception -> INCEPTION_API_KEY or
/// credentials Medic.inception; see Medic.Operation.Agent.APIKey). Blank means Credentials / SYSTEMONE_API_KEY.
Property KeyProvider As %String(MAXLEN = 64);

/// Name of this tier's step in the trace (e.g. Mercury 2.5). Blank means Mock, Jev, Ollama or Laya.
Property Stage As %String(MAXLEN = 64);

Parameter SETTINGS = "ProviderClass:Basic,BaseURL:SystemOne,Model:SystemOne,Credentials:SystemOne:credentialsSelector,TimeoutSeconds:SystemOne,PricePerMTokens:SystemOne,KeyProvider:SystemOne,Stage:Basic";

/// Resolved provider settings handed to Decide().
Property Config As %DynamicObject [ Transient ];

Method OnInit() As %Status
{
	set ..ProviderClass = ..Pick(..ProviderClass, "MEDIC_FAST_PROVIDER", "Medic.Provider.JevMock")
	set key = ""
	if ..Credentials '= "" set key = ##class(Ens.Config.Credentials).GetValue(..Credentials, "Password")
	if ..KeyProvider '= "" set key = ##class(Medic.Operation.Agent).APIKey(..KeyProvider, ##class(Medic.Operation.Agent).Credential(..KeyProvider))
	// A chat model's key never falls back to SYSTEMONE_API_KEY (that would send Jev's key elsewhere).
	set ..Config = {
		"baseUrl": (..Pick(..BaseURL, "SYSTEMONE_BASE_URL")),
		"model": (..ModelId()),
		"apiKey": ($select(..KeyProvider '= "": key, 1: ..Pick(key, "SYSTEMONE_API_KEY"))),
		"timeout": (..TimeoutSeconds),
		"pricePerMTok": (+..Pick(..PricePerMTokens, "SYSTEMONE_PRICE_PER_MTOK", 0))
	}
	$$$LOGINFO("Fast tier provider "_..ProviderClass_$select(..Config.baseUrl '= "": " at "_..Config.baseUrl, 1: ""))
	quit $$$OK
}

/// The model id sent to SystemOne. A Model setting of "-" means none (Laya accepts no model), not SYSTEMONE_MODEL.
Method ModelId() As %String
{
	quit:(..Model = "-") ""
	quit ..Pick(..Model, "SYSTEMONE_MODEL")
}

ClassMethod Pick(pSetting As %String, pEnvVar As %String, pDefault As %String = "") As %String
{
	quit:pSetting'="" pSetting
	set env = $system.Util.GetEnviron(pEnvVar)
	quit $select(env '= "": env, 1: pDefault)
}

Method OnMessage(pRequest As Medic.Msg.FailedMessage, Output pResponse As Medic.Msg.Decision) As %Status
{
	set start = $zhorolog
	set pResponse = ##class(Medic.Msg.Decision).%New()
	set pResponse.CaseId = pRequest.CaseId
	set pResponse.DecidedBy = "fast"
	set sc = $classmethod(..ProviderClass, "Decide", pRequest, pResponse, "", ..Config)
	set pResponse.LatencyMs = ($zhorolog - start) * 1000 \ 1
	if $$$ISOK(sc) {
		do pResponse.AddStep(..StageName(), "ok", pResponse.Action_" "_$fnumber(pResponse.Confidence, "", 2), pResponse.Rationale, pResponse.LatencyMs)
	}
	quit sc
}

/// Trace stage for this provider: Mock, Jev (hosted typesafe endpoint), Ollama (OLLAMA_BASE_URL or
/// Ollama's port 11434) or Laya (any other SystemOne endpoint).
Method StageName() As %String
{
	if ..Stage '= "" quit ..Stage
	if ..ProviderClass = "Medic.Provider.JevMock" quit "Mock"
	set url = ..Config.baseUrl, ollama = $system.Util.GetEnviron("OLLAMA_BASE_URL")
	quit $select(url [ "typesafe": "Jev", ((ollama '= "") && (url = ollama)) || (url [ ":11434"): "Ollama", 1: "Laya")
}

}
