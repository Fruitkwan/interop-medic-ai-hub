/// A decision the policy held for a person also becomes an IRIS Workflow task for the
/// Medic.Reviewers role (Workflow inbox: /csp/user/_DeepSee.UserPortal.Workflow.zen). The reviewer
/// answers Approve, Escalate or Quarantine there; the answer goes through Medic.Actions exactly
/// like a click on the web page. Whoever decides first wins: deciding on the page closes the task.
Class Medic.Process.Review Extends Ens.BusinessProcess
{

/// The EnsLib.Workflow.Operation whose name is the reviewers' Workflow role.
Property WorkflowTarget As Ens.DataType.ConfigName [ InitialExpression = "Medic.Reviewers" ];

Parameter SETTINGS = "WorkflowTarget:Basic";

/// The case under review, kept between the task request and its answer.
Property CaseId As %String(MAXLEN = 128);

Method OnRequest(pRequest As Medic.Msg.ReviewRequest, Output pResponse As Ens.Response) As %Status
{
	set ..CaseId = pRequest.CaseId
	set task = ##class(EnsLib.Workflow.TaskRequest).%New()
	set task.%Actions = "Approve,Escalate,Quarantine"
	set task.%Subject = ..Subject(pRequest.CaseId)_": agent proposes "_pRequest.Action
	set task.%Message = ..Body(pRequest)
	set task.%Priority = $select(pRequest.Severity >= 0.8: 1, pRequest.Severity >= 0.5: 2, 1: 3)
	quit ..SendRequestAsync(..WorkflowTarget, task, 1, "review")
}

/// The reviewer's answer. A task closed because someone decided on the page carries that
/// decision's action and is ignored here (Medic.Actions refuses a second decision anyway).
Method OnResponse(request As Ens.Request, ByRef response As Ens.Response, callrequest As Ens.Request, callresponse As Ens.Response, pCompletionKey As %String) As %Status
{
	quit:'$isobject(callresponse) $$$OK
	set action = $zconvert(callresponse.%Action, "L")
	quit:'$listfind($listbuild("approve", "escalate", "quarantine"), action) $$$OK
	set id = ..DecisionId(..CaseId)
	quit:id="" $$$OK
	set actor = $select(callresponse.%UserName '= "": callresponse.%UserName, 1: "a reviewer")_" (Workflow inbox)"
	try {
		if action = "approve" {
			do ##class(Medic.Actions).Approve(id, actor)
		} else {
			do ##class(Medic.Actions).Override(id, action, "", "decided in the Workflow inbox", actor)
		}
	} catch ex {
		$$$LOGINFO("Workflow answer for "_..CaseId_" not applied: "_$system.Status.GetOneErrorText(ex.AsStatus()))
	}
	quit $$$OK
}

/// Complete the open Workflow task for a case that was just decided elsewhere (the web page).
ClassMethod CloseTask(pCaseId As %String, pAction As %String = "")
{
	try {
		set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT ID FROM EnsLib_Workflow.TaskResponse WHERE TaskStatus_IsComplete = 0 AND ""%Subject"" %STARTSWITH ?", ..Subject(pCaseId)_":")
		// %ExecDirect reports SQL errors in the result, not by throwing.
		if rs.%SQLCODE < 0 $$$ThrowStatus($$$ERROR($$$GeneralError, rs.%Message))
		while rs.%Next() {
			set task = ##class(EnsLib.Workflow.TaskResponse).%OpenId(rs.ID)
			if $isobject(task) do ##class(EnsLib.Workflow.Engine).CompleteTask(task, pAction)
		}
	} catch ex {
		$$$LOGWARNING("Could not close the Workflow task for "_pCaseId_": "_$system.Status.GetOneErrorText(ex.AsStatus()))
	}
}

ClassMethod Subject(pCaseId As %String) As %String
{
	quit "Interop Medic case "_pCaseId
}

/// The decision the policy held for a case. A case has three rows (fast tier, agent, final) in no
/// fixed ID order; only the final one, the row the web page shows, has a Policy step.
ClassMethod DecisionId(pCaseId As %String) As %String
{
	set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT ID FROM Medic_Msg.Decision WHERE CaseId = ?", pCaseId)
	if rs.%SQLCODE < 0 $$$ThrowStatus($$$ERROR($$$GeneralError, rs.%Message))
	set found = ""
	while rs.%Next() {
		set d = ##class(Medic.Msg.Decision).%OpenId(rs.ID)
		if $isobject(d) && (d.TraceJSON [ """stage"":""Policy""") set found = rs.ID
	}
	quit found
}

ClassMethod Body(pRequest As Medic.Msg.ReviewRequest) As %String
{
	set nl = $char(13, 10)
	set text = "The agent proposes "_pRequest.Action_" (confidence "_$fnumber(pRequest.Confidence, "", 2)_", severity "_$fnumber(pRequest.Severity, "", 2)_")."_nl_nl
	set text = text_"Why: "_pRequest.Rationale_nl
	if pRequest.ProposedFix '= "" set text = text_nl_"Proposed fix: "_pRequest.ProposedFix_nl
	if pRequest.RerouteTarget '= "" set text = text_nl_"Reroute to: "_pRequest.RerouteTarget_nl
	quit text_nl_"Approve runs the proposal; Escalate or Quarantine replaces it. The full trace is on the Interop Medic page."
}

}
