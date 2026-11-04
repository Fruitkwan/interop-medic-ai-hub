/// Fast-tier provider for a fast chat model behind an OpenAI-compatible API (POST <baseUrl>chat/completions),
/// such as Inception's Mercury. One JSON-mode call answers the same three questions as System One:
/// the action, the severity and the identity risk. Like Medic.Provider.SystemOne, any failure becomes
/// a zero-confidence escalate so the full agent takes the case.
Class Medic.Provider.ChatFast Extends Medic.Provider.Base
{

Parameter ACTIONS = ",resend,fix_and_resend,reroute,quarantine,escalate,";

XData SYSTEM [ MimeType = text/plain ]
{
You triage one failed HL7 v2 or FHIR message in a hospital integration engine. Choose one action:
resend: the message is valid and a transient connection or server failure stopped delivery.
fix_and_resend: a format or code error can be corrected mechanically without guessing.
reroute: the receiving application is a misspelling or variant of a known receiver.
quarantine: a duplicate, or a truncated or malformed message that must not be resent.
escalate: patient identity is uncertain, data is missing, a critical result is delayed, or a fix would need guessing.
Reply with one JSON object and nothing else:
{"action": "<one of the five>", "confidence": 0.0-1.0, "severity": 0.0-1.0, "identity_risk": 0.0-1.0, "rationale": "one short sentence"}
severity is the risk to a patient if nobody acts (0 cosmetic, 1 possible harm). identity_risk is the
probability that acting on the message would attach clinical data to the wrong patient.
}

ClassMethod Decide(pReq As Medic.Msg.FailedMessage, pDecision As Medic.Msg.Decision, pHint As Medic.Msg.Decision = "", pConfig As %DynamicObject = "") As %Status
{
	set cfg = $select($isobject(pConfig): pConfig, 1: {})
	try {
		if cfg.baseUrl = "" $$$ThrowStatus($$$ERROR($$$GeneralError, "no base URL for the chat model"))
		if cfg.apiKey = "" $$$ThrowStatus($$$ERROR($$$GeneralError, "no API key for the chat model"))
		do ##class(%Net.URLParser).Decompose(cfg.baseUrl, .url)
		set http = ##class(%Net.HttpRequest).%New()
		set http.Server = url("host")
		if $get(url("port")) '= "" set http.Port = url("port")
		if $zconvert($get(url("scheme")), "L") = "https" set http.Https = 1, http.SSLConfiguration = "MedicTLS"
		set http.Timeout = $select(+cfg.timeout > 0: cfg.timeout, 1: 30)
		set http.ContentType = "application/json; charset=utf-8"
		do http.SetHeader("Authorization", "Bearer "_cfg.apiKey)
		do http.EntityBody.Write($zconvert(..BuildRequest(pReq, cfg.model).%ToJSON(), "O", "UTF8"))

		set path = $get(url("path"))
		if $extract(path, *) '= "/" set path = path_"/"
		$$$ThrowOnError(http.Post(path_"chat/completions", , 0))
		// Rate limited: wait as asked (at most 5 s) and try once more, never in a loop.
		if http.HttpResponse.StatusCode = 429 {
			set wait = +http.HttpResponse.GetHeader("RETRY-AFTER")
			hang $select((wait > 0) && (wait <= 5): wait, 1: 2)
			$$$ThrowOnError(http.Post(path_"chat/completions"))
		}
		set status = http.HttpResponse.StatusCode
		if status '= 200 $$$ThrowStatus($$$ERROR($$$GeneralError, "HTTP "_status_": "_$extract(http.HttpResponse.Data.Read(300), 1, 300)))
		set reply = {}.%FromJSON(http.HttpResponse.Data)
		$$$ThrowOnError(..ApplyReply(reply.choices.%Get(0).message.content, pDecision))
		set pDecision.Provider = $classname()_":"_$select(reply.model '= "": reply.model, 1: cfg.model)
		set pDecision.Model = $select(reply.model '= "": reply.model, 1: cfg.model)
		set pDecision.InputTokens = +reply.usage."prompt_tokens", pDecision.OutputTokens = +reply.usage."completion_tokens"
		set pDecision.Completion = reply.choices.%Get(0).message.content
		set pDecision.CostUSD = (+reply.usage."prompt_tokens") * (+cfg.pricePerMTok) / 1000000
	} catch ex {
		do ..Set(pDecision, "escalate", 0, 0.5, "Fast tier unavailable: "_$system.Status.GetOneErrorText(ex.AsStatus()))
	}
	quit $$$OK
}

/// The chat request: the instructions, then the same state text System One gets.
ClassMethod BuildRequest(pReq As Medic.Msg.FailedMessage, pModel As %String) As %DynamicObject
{
	set system = ##class(%Dictionary.CompiledXData).%OpenId($classname()_"||SYSTEM").Data.Read(10000)
	set state = ##class(Medic.Provider.SystemOne).BuildRequest(pReq).state
	set req = {"temperature": 0, "response_format": {"type": "json_object"},
		"messages": [{"role": "system", "content": (system)}, {"role": "user", "content": (state)}]}
	if pModel '= "" set req.model = pModel
	quit req
}

/// Map the model's JSON reply onto pDecision, with the System One wrong-patient guardrail.
ClassMethod ApplyReply(pContent As %String, pDecision As Medic.Msg.Decision) As %Status
{
	set start = $find(pContent, "{"), end = $length(pContent)
	while (end > 0) && ($extract(pContent, end) '= "}") { set end = end - 1 }
	quit:((start = 0) || (end < start)) $$$ERROR($$$GeneralError, "reply has no JSON object: "_$extract(pContent, 1, 200))
	try {
		set obj = {}.%FromJSON($extract(pContent, start - 1, end))
	} catch {
		set obj = ""
	}
	quit:'$isobject(obj) $$$ERROR($$$GeneralError, "reply is not valid JSON: "_$extract(pContent, 1, 200))
	set action = $zconvert(obj.action, "L")
	quit:(..#ACTIONS '[ (","_action_",")) $$$ERROR($$$GeneralError, "unknown action: "_obj.action)
	set conf = ..Clamp(obj.confidence), sev = ..Clamp(obj.severity), idRisk = ..Clamp(obj."identity_risk")
	set why = "Fast tier: "_action_" (p="_$fnumber(conf, "", 2)_", identity risk "_$fnumber(idRisk, "", 2)_")"
	if obj.rationale '= "" set why = why_". "_obj.rationale
	// Guardrail: a likely wrong-patient case is never handled as a routine fix.
	if (idRisk >= 0.7) && (action '= "escalate") {
		set why = "Fast tier chose "_action_" but identity risk is "_$fnumber(idRisk, "", 2)_"; escalating"
		set action = "escalate", conf = idRisk, sev = $select(sev < 0.9: 0.9, 1: sev)
	}
	do ..Set(pDecision, action, conf, sev, why)
	quit $$$OK
}

ClassMethod Clamp(pValue) As %Numeric
{
	set v = +pValue
	quit $select(v < 0: 0, v > 1: 1, 1: v)
}

}
