/// Fast-tier provider for any server speaking the System One API (POST /v1/systemone):
/// TypeSafe Jev (hosted), a hosted Laya API, Laya run locally with laya-serve or ollaya, or
/// Inception's Mercury Decide (the same request at POST /v1/decisions; config "endpoint").
/// One call asks three typed questions: the action (choice), severity (score) and identity risk (noul).
/// Any failure (unreachable server, bad reply) becomes a zero-confidence escalate, so the full agent
/// takes the case instead of the message erroring.
Class Medic.Provider.SystemOne Extends Medic.Provider.Base
{

ClassMethod Decide(pReq As Medic.Msg.FailedMessage, pDecision As Medic.Msg.Decision, pHint As Medic.Msg.Decision = "", pConfig As %DynamicObject = "") As %Status
{
	set cfg = $select($isobject(pConfig): pConfig, 1: {})
	try {
		if cfg.baseUrl = "" $$$ThrowStatus($$$ERROR($$$GeneralError, "no base URL (set BaseURL or SYSTEMONE_BASE_URL)"))
		do ##class(%Net.URLParser).Decompose(cfg.baseUrl, .url)
		set http = ##class(%Net.HttpRequest).%New()
		set http.Server = url("host")
		if $get(url("port")) '= "" set http.Port = url("port")
		if $zconvert($get(url("scheme")), "L") = "https" set http.Https = 1, http.SSLConfiguration = "MedicTLS"
		set http.Timeout = $select(+cfg.timeout > 0: cfg.timeout, 1: 10)
		set http.ContentType = "application/json; charset=utf-8"
		if cfg.apiKey '= "" do http.SetHeader("Authorization", "Bearer "_cfg.apiKey)
		// Encode explicitly: otherwise characters such as an accented name go out as Latin-1 and
		// the server rejects the body.
		do http.EntityBody.Write($zconvert(..BuildRequest(pReq, cfg.model).%ToJSON(), "O", "UTF8"))

		set path = $get(url("path"))
		if $extract(path, *) = "/" set path = $extract(path, 1, *-1)
		set endpoint = $select(cfg.endpoint '= "": cfg.endpoint, 1: "v1/systemone")
		$$$ThrowOnError(http.Post(path_"/"_endpoint, , 0))
		// Rate limited: wait as asked (at most 5 s) and try once more, never in a loop.
		if http.HttpResponse.StatusCode = 429 {
			set wait = +http.HttpResponse.GetHeader("RETRY-AFTER")
			hang $select((wait > 0) && (wait <= 5): wait, 1: 2)
			$$$ThrowOnError(http.Post(path_"/"_endpoint))
		}
		set status = http.HttpResponse.StatusCode
		if status '= 200 $$$ThrowStatus($$$ERROR($$$GeneralError, "HTTP "_status_": "_$extract(http.HttpResponse.Data.Read(300), 1, 300)))
		do ..ApplyAnswers({}.%FromJSON(http.HttpResponse.Data), pDecision, cfg)
	} catch ex {
		do ..Set(pDecision, "escalate", 0, 0.5, "Fast tier unavailable: "_$system.Status.GetOneErrorText(ex.AsStatus()))
	}
	quit $$$OK
}

/// The System One request for one failed message. Error and context go first, because Laya reads
/// the state through a limited token window.
ClassMethod BuildRequest(pReq As Medic.Msg.FailedMessage, pModel As %String = "") As %DynamicObject
{
	set nl = $char(10)
	set ctx = $select(pReq.ContextJSON = "": {}, 1: {}.%FromJSON(pReq.ContextJSON))
	set state = "Error: "_pReq.ErrorText_nl
	if $isobject(ctx.endpoint) {
		set state = state_"Endpoint "_ctx.endpoint.name_": "_$select(ctx.endpoint.up: "up", 1: "down")_", down "_(+ctx.endpoint."down_minutes")_" min"_nl
	}
	if $isobject(ctx."routing_table") {
		set routes = "", it = ctx."routing_table".%GetIterator()
		while it.%GetNext(.key, .target) { set routes = routes_$select(routes = "": "", 1: ", ")_key_" -> "_target }
		set state = state_"Known receivers: "_routes_nl
	}
	set state = state_"Message ("_pReq.Format_"):"_nl_$extract($translate(..Raw(pReq), $char(13), nl), 1, 4000)

	set req = {
		"state": (state),
		"questions": {
			"action": {
				"type": "choice",
				"instructions": "What should an integration engineer do with this failed message?",
				"criteria": {
					"resend": "the message is valid and a transient connection or server failure stopped delivery",
					"fix_and_resend": "a format or code error that can be corrected mechanically without guessing",
					"reroute": "the receiving application is a misspelling or variant of a known receiver",
					"quarantine": "a duplicate, or a truncated or malformed message that must not be resent",
					"escalate": "patient identity is uncertain, data is missing, a critical result is delayed, or a fix would need guessing"
				}
			},
			"severity": {
				"type": "score",
				"instructions": "How much could this failure harm a patient if nobody acts?",
				"criteria": ["cosmetic", "minor", "moderate", "serious", "patient harm possible"]
			},
			"identity_risk": {
				"type": "noul",
				"instructions": "Could acting on this message attach clinical data to the wrong patient?"
			}
		}
	}
	if pModel '= "" set req.model = pModel
	quit req
}

/// Map a System One response onto a decision. Gates on answer_confidence (Laya documents it as the
/// field to gate on); falls back to the chosen option's probability.
ClassMethod ApplyAnswers(pResponse As %DynamicObject, pDecision As Medic.Msg.Decision, pConfig As %DynamicObject = "")
{
	set answers = pResponse.answers
	set a = answers.action
	set action = a.choice
	set conf = $select(a.%IsDefined("answer_confidence"): a."answer_confidence", 1: +a.probabilities.%Get(action))
	set sev = $select($isobject(answers.severity): answers.severity.score / 4, 1: 0.5)
	set idRisk = $select($isobject(answers."identity_risk"): +answers."identity_risk".noul, 1: 0)
	set why = "Fast tier: "_action_" (p="_$fnumber(conf, "", 2)_", identity risk "_$fnumber(idRisk, "", 2)_")"

	// Guardrail: a likely wrong-patient case is never handled as a routine fix.
	if (idRisk >= 0.7) && (action '= "escalate") {
		set why = "Fast tier chose "_action_" but identity risk is "_$fnumber(idRisk, "", 2)_"; escalating"
		set action = "escalate", conf = idRisk, sev = $select(sev < 0.9: 0.9, 1: sev)
	}
	do ..Set(pDecision, action, $select(conf > 1: 1, conf < 0: 0, 1: conf), $select(sev > 1: 1, sev < 0: 0, 1: sev), why)
	set pDecision.Provider = $classname()_":"_$select(pResponse.model '= "": pResponse.model, 1: "unknown")
	set price = $select($isobject(pConfig): +pConfig.pricePerMTok, 1: 0)
	set pDecision.CostUSD = (+pResponse.usage."input_tokens") * price / 1000000
}

}
