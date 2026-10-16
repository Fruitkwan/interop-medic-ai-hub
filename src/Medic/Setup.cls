/// Install, start-up and readiness checks. Everything here is safe to run more than once.
Class Medic.Setup
{

/// Accounts whose password is managed here. CSPSystem is left alone: the web gateway uses it.
Parameter ACCOUNTS = "_SYSTEM,SuperUser,Admin";

/// Demonstration password set at build time, so a fresh container always has a known login.
Parameter DEMOPASSWORD = "SYS";

/// Build time: lookup tables, TLS config, and known passwords with no forced change.
ClassMethod Run() As %Status
{
	set sc = $$$OK
	for pair = "EPR:Medic.To.EPR", "LAB:Medic.To.LIS", "PACS:Medic.To.PACS" {
		set sc = ##class(Ens.Util.LookupTable).%UpdateValue("MedicRouting", $piece(pair, ":"), $piece(pair, ":", 2))
		quit:$$$ISERR(sc)
	}
	quit:$$$ISERR(sc) sc
	set sc = ..CreateTLSConfig()
	quit:$$$ISERR(sc) sc
	quit ..SetPasswords(..#DEMOPASSWORD)
}

/// Container start (docker-compose runs it after IRIS is up): applies IRIS_PASSWORD from .env.
/// It is applied again only when the value in .env changes, so a password changed in the portal
/// survives restarts.
ClassMethod OnStart() As %Status
{
	set password = $system.Util.GetEnviron("IRIS_PASSWORD")
	if password = "" {
		write "Interop Medic: IRIS_PASSWORD not set; accounts keep their current password (demo: "_..#DEMOPASSWORD_")", !
		quit $$$OK
	}
	set salt = $get(^Medic.Config("passwordSalt"))
	if salt = "" set salt = $system.Encryption.GenCryptRand(16), ^Medic.Config("passwordSalt") = salt
	set fingerprint = $system.Encryption.Base64Encode($system.Encryption.SHAHash(256, salt_password))
	if fingerprint = $get(^Medic.Config("passwordFingerprint")) {
		write "Interop Medic: IRIS_PASSWORD unchanged since it was applied", !
		quit $$$OK
	}
	set sc = ..SetPasswords(password)
	if $$$ISOK(sc) {
		set ^Medic.Config("passwordFingerprint") = fingerprint
		write "Interop Medic: IRIS_PASSWORD applied to "_..#ACCOUNTS, !
	} else {
		write "Interop Medic: could not apply IRIS_PASSWORD: "_$system.Status.GetErrorText(sc), !
	}
	quit sc
}

/// Set the password of the managed accounts, without a forced change at next login or expiry.
ClassMethod SetPasswords(pPassword As %String) As %Status
{
	new $namespace
	set $namespace = "%SYS"
	set sc = $$$OK
	for i = 1:1:$length(..#ACCOUNTS, ",") {
		set user = $piece(..#ACCOUNTS, ",", i)
		continue:'##class(Security.Users).Exists(user)
		kill props
		set props("Password") = pPassword, props("ChangePassword") = 0, props("PasswordNeverExpires") = 1
		set sc = ##class(Security.Users).Modify(user, .props)
		quit:$$$ISERR(sc)
	}
	quit sc
}

/// Client TLS config "MedicTLS", used by Medic.Provider.SystemOne for https base URLs.
ClassMethod CreateTLSConfig() As %Status
{
	new $namespace
	set $namespace = "%SYS"
	quit:##class(Security.SSLConfigs).Exists("MedicTLS") $$$OK
	quit ##class(Security.SSLConfigs).Create("MedicTLS")
}

/// Readiness report: docker exec interop-medic iris session IRIS -U USER "##class(Medic.Setup).Doctor()"
ClassMethod Doctor()
{
	write "Interop Medic readiness", !, $zversion, !, !
	do ..Check("Production Medic.Production running", ##class(Ens.Director).IsProductionRunning())
	set fast = ##class(Medic.Operation.FastTier).Pick(##class(Ens.Director).GetHostSettingValue("Medic.FastTier", "ProviderClass"), "MEDIC_FAST_PROVIDER", "Medic.Provider.JevMock")
	do ..Check("Fast tier provider: "_fast, ##class(%Dictionary.CompiledClass).%ExistsId(fast))
	if fast = "Medic.Provider.SystemOne" {
		set url = ##class(Medic.Operation.FastTier).Pick(##class(Ens.Director).GetHostSettingValue("Medic.FastTier", "BaseURL"), "SYSTEMONE_BASE_URL")
		do ..Check("System One base URL: "_$select(url = "": "(not set)", 1: url), url '= "")
	}
	set agent = ##class(Ens.Director).GetHostSettingValue("Medic.Agent", "ProviderClass")
	do ..Check("Agent provider: "_agent, ##class(%Dictionary.CompiledClass).%ExistsId(agent))
	set routes = 0, key = ""
	for { set key = $order(^Ens.LookupTable("MedicRouting", key)) quit:key=""  set routes = routes + 1 }
	do ..Check("Routing table MedicRouting: "_routes_" receivers", routes > 0)
	do ..Check("Dataset mounted at /dataset/cases.jsonl", ##class(%File).Exists("/dataset/cases.jsonl"))
	do ..Check("Demo inbox /data/in", ##class(%File).DirectoryExists("/data/in"))
	new $namespace
	set $namespace = "%SYS"
	do ..Check("TLS config MedicTLS", ##class(Security.SSLConfigs).Exists("MedicTLS"))
	for i = 1:1:$length(..#ACCOUNTS, ",") {
		set user = $piece(..#ACCOUNTS, ",", i)
		kill props
		do ##class(Security.Users).Get(user, .props)
		do ..Check("Account "_user_": no forced password change", '$get(props("ChangePassword")))
	}
	write !, "Sign in at http://localhost:52773/csp/user/EnsPortal.ProductionConfig.zen as _SYSTEM", !
	write "(IRIS_PASSWORD from .env, or "_..#DEMOPASSWORD_" when none is set)", !
}

ClassMethod Check(pLabel As %String, pOK As %Boolean)
{
	write $select(pOK: "  [ok]   ", 1: "  [FAIL] "), pLabel, !
}

}
