/// One row per thing that happened to a decision after it was made (person actions, production events).
Class Medic.Data.Audit Extends %Persistent
{

Property DecisionId As %Integer;

Property CaseId As %String(MAXLEN = 128);

Property At As %TimeStamp;

Property Actor As %String(MAXLEN = 64);

Property Event As %String(MAXLEN = 128);

Property Detail As %String(MAXLEN = 1000);

Index DecisionIdx On DecisionId;

ClassMethod Log(pDecisionId As %Integer, pCaseId As %String, pActor As %String, pEvent As %String, pDetail As %String = "") As %Status
{
	set a = ..%New()
	set a.DecisionId = pDecisionId
	set a.CaseId = pCaseId
	set a.At = $zdatetime($ztimestamp, 3, 1, 3)
	set a.Actor = pActor
	set a.Event = pEvent
	set a.Detail = pDetail
	quit a.%Save()
}

/// Audit rows for one decision, oldest first.
ClassMethod ForDecision(pDecisionId As %Integer) As %DynamicArray
{
	set out = []
	set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT ""At"", Actor, Event, Detail FROM Medic_Data.Audit WHERE DecisionId = ? ORDER BY ID", pDecisionId)
	while rs.%Next() {
		do out.%Push({"at": (rs.At), "actor": (rs.Actor), "event": (rs.Event), "detail": (rs.Detail)})
	}
	quit out
}

}
