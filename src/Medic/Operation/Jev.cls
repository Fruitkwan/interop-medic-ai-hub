/// System 1: one fast typed call per failed message.
Class Medic.Operation.Jev Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

Property ProviderClass As %String(MAXLEN = 128) [ InitialExpression = "Medic.Provider.JevMock" ];

Parameter SETTINGS = "ProviderClass:Basic";

Method OnMessage(pRequest As Medic.Msg.FailedMessage, Output pResponse As Medic.Msg.Decision) As %Status
{
	set start = $zhorolog
	set pResponse = ##class(Medic.Msg.Decision).%New()
	set pResponse.CaseId = pRequest.CaseId
	set pResponse.DecidedBy = "jev"
	set sc = $classmethod(..ProviderClass, "Decide", pRequest, pResponse)
	set pResponse.LatencyMs = ($zhorolog - start) * 1000 \ 1
	quit sc
}

}
