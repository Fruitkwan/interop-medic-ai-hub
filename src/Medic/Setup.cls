/// Seeds lookup tables the tools read. Safe to run more than once.
Class Medic.Setup
{

ClassMethod Run() As %Status
{
	set sc = $$$OK
	for pair = "EPR:Medic.To.EPR", "LAB:Medic.To.LIS", "PACS:Medic.To.PACS" {
		set sc = ##class(Ens.Util.LookupTable).%UpdateValue("MedicRouting", $piece(pair, ":"), $piece(pair, ":", 2))
		quit:$$$ISERR(sc)
	}
	quit sc
}

}
