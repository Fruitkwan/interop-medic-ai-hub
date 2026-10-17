/// Unit tests for Medic.Provider.AIHubAgent's parsing, prompt and fail-safe. They need no AI Hub.
/// Run: do ##class(%UnitTest.Manager).DebugRunTestCase("", "Medic.Test.AIHubAgent", "", "")
Class Medic.Test.AIHubAgent Extends %UnitTest.TestCase
{

Method TestParsesPlainJSON()
{
	set d = ##class(Medic.Msg.Decision).%New()
	set sc = ##class(Medic.Provider.AIHubAgent).ParseDecision("{""action"": ""resend"", ""confidence"": 0.92, ""severity"": 0.3, ""rationale"": ""Endpoint timed out"", ""proposed_fix"": ""Resend unchanged"", ""reroute_target"": """"}", d)
	do $$$AssertStatusOK(sc)
	do $$$AssertEquals(d.Action, "resend")
	do $$$AssertEquals(d.Confidence, 0.92)
	do $$$AssertEquals(d.ProposedFix, "Resend unchanged")
}

Method TestToleratesFencesAndProse()
{
	set d = ##class(Medic.Msg.Decision).%New()
	set reply = "Here is my decision:"_$char(10)_"```json"_$char(10)_"{""action"": ""Reroute"", ""confidence"": 1.4, ""severity"": -1, ""rationale"": ""EPRR is EPR"", ""reroute_target"": ""Medic.To.EPR""}"_$char(10)_"```"
	do $$$AssertStatusOK(##class(Medic.Provider.AIHubAgent).ParseDecision(reply, d))
	do $$$AssertEquals(d.Action, "reroute", "action is case-insensitive")
	do $$$AssertEquals(d.RerouteTarget, "Medic.To.EPR")
	do $$$AssertEquals(d.Confidence, 1, "clamped to 1")
	do $$$AssertEquals(d.Severity, 0, "clamped to 0")
}

Method TestRerouteWithoutTargetEscalates()
{
	set d = ##class(Medic.Msg.Decision).%New()
	do $$$AssertStatusOK(##class(Medic.Provider.AIHubAgent).ParseDecision("{""action"": ""reroute"", ""confidence"": 0.9, ""severity"": 0.4, ""rationale"": ""typo""}", d))
	do $$$AssertEquals(d.Action, "escalate")
	do $$$AssertTrue(d.Confidence <= 0.5)
	do $$$AssertEquals(d.RerouteTarget, "")
}

Method TestRejectsBadReplies()
{
	set d = ##class(Medic.Msg.Decision).%New()
	do $$$AssertStatusNotOK(##class(Medic.Provider.AIHubAgent).ParseDecision("I think you should resend it.", d), "no JSON")
	do $$$AssertStatusNotOK(##class(Medic.Provider.AIHubAgent).ParseDecision("{""action"": ""delete""}", d), "unknown action")
	do $$$AssertStatusNotOK(##class(Medic.Provider.AIHubAgent).ParseDecision("{""action"": }", d), "broken JSON")
}

Method TestPromptIncludesHint()
{
	set req = ##class(Medic.Test.SystemOne).Request()
	set hint = ##class(Medic.Msg.Decision).%New()
	set hint.Action = "resend", hint.Confidence = 0.88, hint.Severity = 0.9, hint.Rationale = "Transport failure"
	set text = ##class(Medic.Provider.AIHubAgent).Prompt(req, hint)
	do $$$AssertTrue(text [ "Error: ERROR #5023")
	do $$$AssertTrue(text [ "Fast classifier verdict (a hint, not a fact): resend")
	do $$$AssertTrue(text [ "PID|1||12345678")
}

Method TestToolValueIsReadable()
{
	set cls = "Medic.Provider.AIHubAgent"
	do $$$AssertEquals($classmethod(cls, "ToolValue", "SearchPrecedents", "[{""caseId"":""c-17"",""action"":""resend""},{""caseId"":""c-9""}]"), "precedent c-17")
	do $$$AssertEquals($classmethod(cls, "ToolValue", "SearchPrecedents", "[{\""caseId\"":\""c-17\"",\""action\"":\""re"), "precedent c-17", "truncated and escaped")
	do $$$AssertEquals($classmethod(cls, "ToolValue", "SearchPrecedents", "[]"), "none")
	do $$$AssertEquals($classmethod(cls, "ToolValue", "ValidateHL7", "{""valid"":true,""docType"":""ORU_R01""}"), "valid")
	do $$$AssertEquals($classmethod(cls, "ToolValue", "ValidateHL7", "{""valid"":false,""error"":""x""}"), "invalid")
	do $$$AssertEquals($classmethod(cls, "ToolValue", "CheckEndpoint", "{\""name\"":\""Medic.To.EPR\"",\""queueDepth\"":12}"), "queue 12")
	do $$$AssertEquals($classmethod(cls, "ToolValue", "GetRoutingRule", "Medic.To.EPR"), "Medic.To.EPR")
	do $$$AssertEquals($classmethod(cls, "ToolValue", "ClosestRoute", "{""result"":""Medic.To.EPR""}"), "Medic.To.EPR")
	do $$$AssertEquals($classmethod(cls, "ToolValue", "ClosestRoute", ""), "no match")
	do $$$AssertEquals($classmethod(cls, "ToolValue", "GetRoutingRule", "{""result"":""""}"), "no match")
	// The real AI Hub audit shape: tool_name + result_json, JSON escaped two or three levels deep.
	set bs = $char(92)
	set real = "{"_$char(34)_"tool_name"_$char(34)_":"_$char(34)_"CheckEndpoint"_$char(34)_","_$char(34)_"result_json"_$char(34)_":"_$char(34)_bs_$char(34)_"{"_bs_bs_bs_$char(34)_"name"_bs_bs_bs_$char(34)_":"_bs_bs_bs_$char(34)_"Medic.To.EPR"_bs_bs_bs_$char(34)_","_bs_bs_bs_$char(34)_"queueDepth"_bs_bs_bs_$char(34)_":7}"_bs_$char(34)_$char(34)_"}"
	do $$$AssertEquals($classmethod(cls, "ToolValue", "CheckEndpoint", real), "queue 7", "real escaped shape")
	set real = "{"_$char(34)_"tool_name"_$char(34)_":"_$char(34)_"ClosestRoute"_$char(34)_","_$char(34)_"result_json"_$char(34)_":"_$char(34)_bs_$char(34)_"Medic.To.EPR"_bs_$char(34)_$char(34)_","_$char(34)_"display_text"_$char(34)_":null}"
	do $$$AssertEquals($classmethod(cls, "ToolValue", "ClosestRoute", real), "Medic.To.EPR", "real routing shape")
	set v = $classmethod(cls, "ToolValue", "Other", "{\""a\"":\""some long text that goes on and on and on past forty chars\""}")
	do $$$AssertTrue(($length(v) <= 40) && (v '[ "{") && (v '[ "\") && (v '[ """"), "fallback is short and clean: "_v)
}

Method TestErrorTextIsShort()
{
	set cls = "Medic.Provider.AIHubAgent", nl = $char(10)
	set raw = "ERROR <%AICore>ProviderError: Provider 'gemini' error: Rate limit exceeded: Rate limit exceeded (HTTP 429): [{"_nl_"  ""error"": {"_nl_"    ""code"": 429,"_nl_"    ""message"": ""Quota exceeded.\nPlease retry in 14h37m45.634481496s."","_nl_"    ""status"": ""RESOURCE_EXHAUSTED""}}]"
	do $$$AssertEquals($classmethod(cls, "ErrorText", raw), "gemini quota or rate limit reached (HTTP 429); retry in 14h37m45s")
	set raw = "ERROR <%AICore>ProviderError: Provider 'openai' error: HTTP 404: {"_nl_"""error"": ""model 'qwen9' not found""}"
	do $$$AssertEquals($classmethod(cls, "ErrorText", raw), "ERROR <%AICore>ProviderError: Provider 'openai' error: HTTP 404")
	do $$$AssertEquals($classmethod(cls, "ErrorText", "AIHUB_API_KEY is not set"), "AIHUB_API_KEY is not set")
	set raw = "ERROR <%AICore>ProviderError: Provider 'openai' error: API error: error sending request for url (http://host.docker.internal:11434/v1/chat/completions): error sending request"
	do $$$AssertEquals($classmethod(cls, "ErrorText", raw), "openai request failed or timed out (AI Hub waits about 60 s per request)")
	do $$$AssertTrue($classmethod(cls, "IsOllama", "http://host.docker.internal:11434/v1/"))
	do $$$AssertNotTrue($classmethod(cls, "IsOllama", "https://api.openai.com/v1/"))
}

Method TestFailsSafeWithoutAIHub()
{
	quit:##class(%Dictionary.CompiledClass).%ExistsId("Medic.AIHub.TriageAgent")
	set d = ##class(Medic.Msg.Decision).%New()
	set sc = ##class(Medic.Provider.AIHubAgent).Decide(##class(Medic.Test.SystemOne).Request(), d)
	do $$$AssertStatusOK(sc)
	do $$$AssertEquals(d.Action, "escalate")
	do $$$AssertEquals(d.Confidence, 0)
	do $$$AssertTrue(d.Rationale [ "not installed")
}

}
