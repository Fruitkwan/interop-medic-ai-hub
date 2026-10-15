/// Demo input: picks up one JSON case file (from dataset/generate.py --cases-dir) per message.
Class Medic.Service.DemoFeed Extends Ens.BusinessService
{

Parameter ADAPTER = "EnsLib.File.InboundAdapter";

Property TargetConfigName As Ens.DataType.ConfigName [ InitialExpression = "Medic.Triage" ];

Parameter SETTINGS = "TargetConfigName:Basic";

Method OnProcessInput(pInput As %Stream.Object, Output pOutput As %RegisteredObject) As %Status
{
	set sc = $$$OK
	try {
		set case = {}.%FromJSON(pInput)
		set req = ##class(Medic.Msg.FailedMessage).%New()
		set req.CaseId = case."case_id"
		set req.Format = case.format
		do req.RawMessage.Write(case."raw_message")
		set req.ErrorText = case."error_text"
		set req.ContextJSON = case.context.%ToJSON()
		set sc = ..SendRequestAsync(..TargetConfigName, req)
	} catch ex {
		set sc = ex.AsStatus()
	}
	quit sc
}

}
