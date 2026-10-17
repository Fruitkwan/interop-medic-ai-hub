/// API keys a judge typed into the web page, held only while their one triage request runs.
/// The page keeps keys in its own tab (sessionStorage) and sends only those the chosen models need
/// with each POST /triage. They go into ^IRIS.Temp.MedicKeys (IRISTEMP: not journaled, gone on
/// restart) under a random token; the message carries only the token, and Dispatch drops it as soon
/// as the request ends. Keys never reach host settings, messages, the trace, logs or replies.
Class Medic.API.Keys
{

/// Tokens left behind by a crashed request are purged after this many seconds.
Parameter TTL = 900;

/// Store pKeys ({"provider": "key", ...}) and return the token, or "" when there are none.
/// Throws a "bad request:" error for anything that does not look like a provider name and key.
ClassMethod Put(pKeys As %DynamicObject) As %String
{
	do ..Purge()
	quit:'$isobject(pKeys) ""
	set token = $translate($system.Util.CreateGUID(), "{}-", ""), n = 0
	// Stamp first, so a concurrent Purge never mistakes a half-written token for an old one.
	set ^IRIS.Temp.MedicKeys(token) = $zdatetime($horolog, -2)
	set it = pKeys.%GetIterator()
	while it.%GetNext(.provider, .key) {
		continue:key=""
		set n = n + 1
		if (n > 20) || '$match(provider, "[A-Za-z0-9_.-]{1,32}") || ($length(key) > 512) || '$match(key, "[\x21-\x7E]+") {
			kill ^IRIS.Temp.MedicKeys(token)
			$$$ThrowStatus($$$ERROR($$$GeneralError, "bad request: keys must be {""provider"": ""key""} with printable keys"))
		}
		set ^IRIS.Temp.MedicKeys(token, $zconvert(provider, "L")) = key
	}
	if n = 0 {
		kill ^IRIS.Temp.MedicKeys(token)
		quit ""
	}
	quit token
}

/// The key the judge gave for pProvider in this request, or "".
ClassMethod Get(pToken As %String, pProvider As %String) As %String
{
	quit:((pToken = "") || (pProvider = "")) ""
	quit $get(^IRIS.Temp.MedicKeys(pToken, $zconvert(pProvider, "L")))
}

ClassMethod Drop(pToken As %String)
{
	if pToken '= "" kill ^IRIS.Temp.MedicKeys(pToken)
}

/// Replace every key of this request in pText with "***", for error texts that echo a key back.
ClassMethod Scrub(pToken As %String, pText As %String) As %String
{
	quit:((pToken = "") || (pText = "")) pText
	set p = ""
	for {
		set p = $order(^IRIS.Temp.MedicKeys(pToken, p), 1, key)
		quit:p=""
		if $length(key) >= 8 set pText = $replace(pText, key, "***")
	}
	quit pText
}

ClassMethod Purge() [ Private ]
{
	set now = $zdatetime($horolog, -2), t = ""
	for {
		set t = $order(^IRIS.Temp.MedicKeys(t))
		quit:t=""
		if (now - $get(^IRIS.Temp.MedicKeys(t), 0)) > ..#TTL kill ^IRIS.Temp.MedicKeys(t)
	}
}

}
