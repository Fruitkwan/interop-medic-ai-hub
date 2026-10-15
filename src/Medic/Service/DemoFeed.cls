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
		set req = ##class(Medic.Msg.FailedMessage).FromCase({}.%FromJSON(pInput))
		set sc = ..SendRequestAsync(..TargetConfigName, req)
	} catch ex {
		set sc = ex.AsStatus()
	}
	quit sc
}

}
