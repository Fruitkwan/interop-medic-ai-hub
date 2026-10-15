/// Seeds lookup tables the tools read and the TLS config for hosted APIs. Safe to run more than once.
Class Medic.Setup
{

ClassMethod Run() As %Status
{
	set sc = $$$OK
	for pair = "EPR:Medic.To.EPR", "LAB:Medic.To.LIS", "PACS:Medic.To.PACS" {
		set sc = ##class(Ens.Util.LookupTable).%UpdateValue("MedicRouting", $piece(pair, ":"), $piece(pair, ":", 2))
		quit:$$$ISERR(sc)
	}
	quit:$$$ISERR(sc) sc
	quit ..CreateTLSConfig()
}

/// Client TLS config "MedicTLS", used by Medic.Provider.SystemOne for https base URLs.
ClassMethod CreateTLSConfig() As %Status
{
	new $namespace
	set $namespace = "%SYS"
	quit:##class(Security.SSLConfigs).Exists("MedicTLS") $$$OK
	quit ##class(Security.SSLConfigs).Create("MedicTLS")
}

}
