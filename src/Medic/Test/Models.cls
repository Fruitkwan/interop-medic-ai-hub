/// Unit tests for the agent model list (MEDIC_AGENT_MODELS) and the server-side key lookup.
/// Run: do ##class(%UnitTest.Manager).DebugRunTestCase("", "Medic.Test.Models", "", "")
Class Medic.Test.Models Extends %UnitTest.TestCase
{

Parameter CRED = "Medic.zztestprovider";

Method TestParsesLabelsProvidersAndModels()
{
	set list = ##class(Medic.API.Models).ParseModels(" Gemini=gemini:gemini-3.5-flash, GPT=OpenAI:gpt-5-mini ,Claude=anthropic:claude-sonnet-5-5,Grok=xai:grok-4")
	do $$$AssertEquals(list.%Size(), 4)
	do $$$AssertEquals(list.%Get(0).%ToJSON(), "{""label"":""Gemini"",""provider"":""gemini"",""model"":""gemini-3.5-flash""}")
	do $$$AssertEquals(list.%Get(1).provider, "openai", "provider is lower-cased")
	do $$$AssertEquals(list.%Get(1).label, "GPT", "spaces trimmed")
	do $$$AssertEquals(list.%Get(3).model, "grok-4")
}

Method TestDefaultsAndEdgeCases()
{
	set list = ##class(Medic.API.Models).ParseModels("anthropic,openai:,Local=openrouter:qwen/qwen3:8b,,Mock=openai:x,GPT=openai:dup")
	do $$$AssertEquals(list.%Size(), 3, "blank, reserved and duplicate labels dropped")
	do $$$AssertEquals(list.%Get(0).label, "Claude", "label from the provider")
	do $$$AssertEquals(list.%Get(0).model, "", "blank model means the provider default")
	do $$$AssertEquals(list.%Get(1).label, "GPT")
	do $$$AssertEquals(list.%Get(2).model, "qwen/qwen3:8b", "everything after the first colon is the model")
	do $$$AssertEquals(##class(Medic.API.Models).ParseModels("").%Size(), 0)
	do $$$AssertEquals(##class(Medic.API.Models).Nice("deepseek"), "Deepseek")
}

Method TestKeyFromCredentials()
{
	do ##class(Ens.Config.Credentials).%DeleteId(..#CRED)
	do $$$AssertEquals(##class(Medic.Operation.Agent).Credential("zzTestProvider"), "", "no credentials yet")
	do $$$AssertEquals(##class(Medic.Operation.Agent).APIKey("zzTestProvider"), "", "no env var either")
	do $$$AssertStatusOK(##class(Ens.Config.Credentials).SetCredential(..#CRED, "", "sk-test-not-real", 1))
	do $$$AssertEquals(##class(Medic.Operation.Agent).Credential("zzTestProvider"), ..#CRED)
	do $$$AssertEquals(##class(Medic.Operation.Agent).APIKey("zzTestProvider", ..#CRED), "sk-test-not-real")
	do $$$AssertNotTrue(##class(Medic.Operation.Agent).HasKey("zzTestProvider"), "an unknown provider without ZZTESTPROVIDER_BASE_URL is never offered")
	do $$$AssertEquals(##class(Medic.Operation.Agent).BaseURL("zzTestProvider"), "")
	do ##class(Ens.Config.Credentials).%DeleteId(..#CRED)
}

/// A hosted provider with no key escalates before any request leaves the server.
Method TestHostedProviderWithoutKeyEscalates()
{
	set req = ##class(Medic.Test.SystemOne).Request(), d = ##class(Medic.Msg.Decision).%New()
	do $$$AssertStatusOK(##class(Medic.Provider.AIHubAgent).Decide(req, d, "", {"provider": "openai", "model": "gpt-5-mini"}))
	do $$$AssertEquals(d.Action, "escalate")
	do $$$AssertEquals(d.Confidence, 0)
	if ##class(%Dictionary.CompiledClass).%ExistsId("Medic.AIHub.TriageAgent") {
		do $$$AssertTrue(d.Rationale [ "no API key configured for provider openai", d.Rationale)
	}
}

Method TestFastReservesItsOwnNames()
{
	set list = ##class(Medic.API.Models).ParseModels("Jev=openai:x,Mercury 2.5=inception:mercury-2.5", ",mock,jev,laya,")
	do $$$AssertEquals(list.%Size(), 1)
	do $$$AssertEquals(list.%Get(0).label, "Mercury 2.5", "labels may contain spaces")
}

/// The chat fast tier maps a JSON reply and keeps the wrong-patient guardrail.
Method TestChatFastReply()
{
	set cls = "Medic.Provider.ChatFast", d = ##class(Medic.Msg.Decision).%New()
	do $$$AssertStatusOK($classmethod(cls, "ApplyReply", "{""action"":""Resend"",""confidence"":0.93,""severity"":0.2,""identity_risk"":0.05,""rationale"":""timeout""}", d))
	do $$$AssertEquals(d.Action, "resend")
	do $$$AssertEquals(d.Confidence, 0.93)
	set d = ##class(Medic.Msg.Decision).%New()
	do $$$AssertStatusOK($classmethod(cls, "ApplyReply", "```json"_$char(10)_"{""action"":""fix_and_resend"",""confidence"":0.9,""severity"":0.3,""identity_risk"":0.8}"_$char(10)_"```", d))
	do $$$AssertEquals(d.Action, "escalate", "identity risk 0.8 forces escalate")
	do $$$AssertTrue(d.Severity >= 0.9)
	do $$$AssertStatusNotOK($classmethod(cls, "ApplyReply", "{""action"":""delete""}", d))
	do $$$AssertStatusNotOK($classmethod(cls, "ApplyReply", "no json here", d))
	set req = $classmethod(cls, "BuildRequest", ##class(Medic.Test.SystemOne).Request(), "mercury-2.5")
	do $$$AssertEquals(req.model, "mercury-2.5")
	do $$$AssertTrue(req.messages.%Get(0).content [ "identity_risk")
	do $$$AssertTrue(req.messages.%Get(1).content [ "Error: ")
}

/// ollama:<model> entries need OLLAMA_BASE_URL and no key.
Method TestOllamaEntriesNeedNoKey()
{
	set cls = "Medic.Operation.Agent", url = $system.Util.GetEnviron("OLLAMA_BASE_URL")
	if url = "" {
		do $$$AssertEquals($classmethod(cls, "BaseURL", "ollama"), "")
		do $$$AssertNotTrue($classmethod(cls, "HasKey", "ollama"))
	} else {
		do $$$AssertEquals($extract($classmethod(cls, "BaseURL", "Ollama"), *-3, *), "/v1/")
		do $$$AssertTrue($classmethod(cls, "HasKey", "ollama"))
	}
}

Method TestRejectsUnknownAgent()
{
	set err = ""
	try {
		do ##class(Medic.API.Models).Set("Mock", "NoSuchModel")
	} catch ex {
		set err = $system.Status.GetOneErrorText(ex.AsStatus())
	}
	do $$$AssertTrue(err [ "not available", err)
}

}
