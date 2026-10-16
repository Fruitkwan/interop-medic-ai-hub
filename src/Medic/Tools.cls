/// Read-only tools the agent can call. Each returns plain values or a JSON string so they can be
/// exposed unchanged through an AI Hub toolset and the MCP service.
Class Medic.Tools
{

/// Parse and structurally validate an HL7 v2 message. DocType defaults to 2.5:<MSH-9.3>.
ClassMethod ValidateHL7(pRaw As %String, pDocType As %String = "") As %String
{
	set msg = ##class(EnsLib.HL7.Message).ImportFromString(pRaw, .sc)
	if $$$ISERR(sc) quit {"valid": false, "error": ($system.Status.GetErrorText(sc))}.%ToJSON()
	if pDocType = "" set pDocType = "2.5:"_msg.GetValueAt("1:9.3")
	do msg.PokeDocType(pDocType)
	set sc = msg.BuildMap()
	if $$$ISERR(sc) quit {"valid": false, "docType": (pDocType), "error": ($system.Status.GetErrorText(sc))}.%ToJSON()
	quit {"valid": true, "docType": (pDocType)}.%ToJSON()
}

/// Production config item that a receiving application routes to, or "".
ClassMethod GetRoutingRule(pReceiver As %String) As %String
{
	quit ##class(Ens.Util.FunctionSet).Lookup("MedicRouting", pReceiver, "")
}

/// Queue depth of a production item.
ClassMethod CheckEndpoint(pConfigName As %String) As %String
{
	quit {"name": (pConfigName), "queueDepth": (##class(Ens.Queue).GetCount(pConfigName))}.%ToJSON()
}

/// Best known route for a misspelt receiver: exact, prefix, or same letters after normalising
/// (EPRR, EP R, epr -> EPR; LAB_TEST, LBA -> LAB; PAC -> PACS). pTable is a dynamic object
/// receiver -> config name; when omitted the MedicRouting lookup table is used.
ClassMethod ClosestRoute(pReceiver As %String, pTable As %DynamicObject = "") As %String
{
	if '$isobject(pTable) set pTable = ..RoutingTable()
	set norm = $zstrip($zconvert(pReceiver, "U"), "*PWNC")
	quit:norm="" ""
	set it = pTable.%GetIterator(), best = ""
	while it.%GetNext(.key, .target) {
		if norm = key return target
		set prefix = ($extract(norm, 1, $length(key)) = key) || (($length(norm) >= 3) && ($extract(key, 1, $length(norm)) = norm))
		if prefix || (..SortedLetters(norm) = ..SortedLetters(key)) set best = target
	}
	quit best
}

/// Past person-approved decisions whose failure text resembles pErrorText: a JSON array of up to 3
/// {caseId, action, rerouteTarget, decidedBy, similarity, summary}, most similar first.
ClassMethod SearchPrecedents(pErrorText As %String) As %String
{
	quit ##class(Medic.Data.Precedent).Search(pErrorText, 3).%ToJSON()
}

ClassMethod RoutingTable() As %DynamicObject
{
	set tbl = {}, key = ""
	for {
		set key = $order(^Ens.LookupTable("MedicRouting", key), 1, target)
		quit:key=""
		do tbl.%Set(key, target)
	}
	quit tbl
}

ClassMethod SortedLetters(pText As %String) As %String
{
	for i = 1:1:$length(pText) set n($extract(pText, i)) = $get(n($extract(pText, i))) + 1
	set out = "", ch = ""
	for {
		set ch = $order(n(ch))
		quit:ch=""
		set out = out_$translate($justify("", n(ch)), " ", ch)
	}
	quit out
}

}
