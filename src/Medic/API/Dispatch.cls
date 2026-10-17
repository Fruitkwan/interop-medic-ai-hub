/// REST API behind the judge-facing web page, served at /medic/api (same origin as the static page).
/// Errors are {"error": "<text>"}: 400 for bad input, 409 when a person already decided, else 500.
Class Medic.API.Dispatch Extends %CSP.REST
{

Parameter CONTENTTYPE = "application/json";

Parameter CHARSET = "utf-8";

Parameter HandleCorsRequest = 0;

Parameter MAXMESSAGE = 100000;

/// Prefix of the errors this class raises for bad input (mapped to 400).
Parameter BADREQUEST = "bad request: ";

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/health" Method="GET" Call="Health"/>
  <Route Url="/scenarios" Method="GET" Call="Scenarios"/>
  <Route Url="/cases/random" Method="GET" Call="RandomCases"/>
  <Route Url="/triage" Method="POST" Call="Triage"/>
  <Route Url="/decisions/:id/approve" Method="POST" Call="Approve"/>
  <Route Url="/decisions/:id/override" Method="POST" Call="Override"/>
  <Route Url="/models" Method="GET" Call="GetModels"/>
  <Route Url="/models" Method="POST" Call="SetModels"/>
</Routes>
}

/// {"mode":"live","aihub":bool,"build":"<short version>"}
ClassMethod Health() As %Status
{
	try {
		set health = {"mode": "live", "build": ($system.Version.GetNumber())}
		do health.%Set("aihub", ##class(%Dictionary.CompiledClass).%ExistsId("%AI.Agent"), "boolean")
		do ..Reply(health)
	} catch ex { do ..Fail(ex) }
	quit $$$OK
}

ClassMethod Scenarios() As %Status
{
	try { do ..Reply(##class(Medic.API.Scenarios).List()) } catch ex { do ..Fail(ex) }
	quit $$$OK
}

ClassMethod RandomCases() As %Status
{
	try { do ..Reply(##class(Medic.API.Scenarios).Random(+$get(%request.Data("n", 1), 5))) } catch ex { do ..Fail(ex) }
	quit $$$OK
}

/// Body {"case": {...}} runs through Medic.Triage synchronously; returns Medic.Actions.DecisionJSON.
ClassMethod Triage() As %Status
{
	try {
		set body = ..Body()
		set case = body.case
		if '$isobject(case) || ('case.%IsA("%DynamicObject")) do ..Throw400("body needs a case object")
		set raw = case."raw_message"
		if raw = "" do ..Throw400("raw_message is empty")
		if $length(raw) > ..#MAXMESSAGE do ..Throw400("raw_message is longer than "_..#MAXMESSAGE_" characters")
		if case.format = "" set case.format = "hl7v2"
		if (case.format = "fhir") {
			if '..IsJSON(raw) do ..Throw400("raw_message is not valid JSON")
		}
		if case."case_id" = "" set case."case_id" = "WEB-"_$translate($system.Util.CreateGUID(), "{}-", "")
		if case."error_text" = "" set case."error_text" = ""
		if '$isobject(case.context) set case.context = {}

		$$$ThrowOnError(##class(Ens.Director).CreateBusinessService("Medic.Eval", .svc))
		set target = "Medic.Triage"
		$$$ThrowOnError(svc.ProcessInput(##class(Medic.Msg.FailedMessage).FromCase(case), .decision, .target))
		do ..Reply(##class(Medic.Actions).DecisionJSON(decision))
	} catch ex { do ..Fail(ex) }
	quit $$$OK
}

ClassMethod Approve(pId As %Integer) As %Status
{
	try {
		set body = ..Body(1)
		set actor = $select(body.actor '= "": body.actor, 1: "demo-user")
		do ..Reply(##class(Medic.Actions).Approve(pId, actor))
	} catch ex { do ..Fail(ex) }
	quit $$$OK
}

ClassMethod Override(pId As %Integer) As %Status
{
	try {
		set body = ..Body()
		set actor = $select(body.actor '= "": body.actor, 1: "demo-user")
		do ..Reply(##class(Medic.Actions).Override(pId, body.action, body.rerouteTarget, body.reason, actor))
	} catch ex { do ..Fail(ex) }
	quit $$$OK
}

ClassMethod GetModels() As %Status
{
	try { do ..Reply(##class(Medic.API.Models).Get()) } catch ex { do ..Fail(ex) }
	quit $$$OK
}

ClassMethod SetModels() As %Status
{
	try {
		set body = ..Body()
		do ..Reply(##class(Medic.API.Models).Set(body.fast, body.agent))
	} catch ex { do ..Fail(ex) }
	quit $$$OK
}

/// Write the JSON value as the response.
ClassMethod Reply(pJSON As %DynamicAbstractObject) [ Private ]
{
	write pJSON.%ToJSON()
}

/// The request body as a dynamic object (UTF-8 decoded). An empty body is {} when pOptional.
ClassMethod Body(pOptional As %Boolean = 0) As %DynamicObject [ Private ]
{
	set text = ""
	if $isobject(%request.Content) {
		while '%request.Content.AtEnd { set text = text_%request.Content.Read(32000) }
	}
	if $zstrip(text, "*W") = "" {
		if pOptional quit {}
		do ..Throw400("request body is empty")
	}
	// Bytes arrive undecoded unless the client declared a charset; decode when they are UTF-8.
	set decoded = $zconvert(text, "I", "UTF8")
	try { set obj = {}.%FromJSON(decoded) } catch { do ..Throw400("request body is not valid JSON") }
	if 'obj.%IsA("%DynamicObject") do ..Throw400("request body must be a JSON object")
	quit obj
}

ClassMethod IsJSON(pText As %String) As %Boolean [ Private ]
{
	try { set obj = {}.%FromJSON(pText), ok = 1 } catch { set ok = 0 }
	quit ok
}

ClassMethod Throw400(pText As %String) [ Private ]
{
	throw ##class(%Exception.StatusException).CreateFromStatus($$$ERROR($$$GeneralError, ..#BADREQUEST_pText))
}

/// POSTs must be application/json: a cross-site form or text/plain POST is refused before it reaches a route.
ClassMethod OnPreDispatch(pUrl As %String, pMethod As %String, ByRef pContinue As %Boolean) As %Status
{
	if pMethod = "POST", $zconvert($piece(%request.ContentType, ";"), "L") '= "application/json" {
		set %response.Status = "415 Unsupported Media Type"
		write {"error": "Content-Type must be application/json"}.%ToJSON()
		set pContinue = 0
	}
	quit $$$OK
}

/// Map an exception to an HTTP status and an {"error"} body.
ClassMethod Fail(ex As %Exception.AbstractException) [ Private ]
{
	set text = $system.Status.GetOneErrorText(ex.AsStatus())
	set status = $select(text [ "already decided by a person": 409,
		(text [ "reroute needs a target") || (text [ "unknown action") || (text [ "unknown model")
			|| (text [ ..#BADREQUEST): 400,
		1: 500)
	set %response.Status = $case(status, 400: "400 Bad Request", 409: "409 Conflict", : "500 Internal Server Error")
	write {"error": (text)}.%ToJSON()
}

}
