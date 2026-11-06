/// Triage one failed message: ask the agent, apply the auto-apply policy, reply.
Class Medic.Process.Triage Extends Ens.BusinessProcessBPL
{

Property AgentTarget As Ens.DataType.ConfigName [ InitialExpression = "Medic.Agent" ];

/// Minimum confidence to apply a decision without a human.
Property AutoApplyThreshold As %Numeric [ InitialExpression = 0.9 ];

/// A decision at or above this severity always waits for a person.
Property AutoApplyMaxSeverity As %Numeric [ InitialExpression = 0.6 ];

/// When on, nothing is applied; every decision is only recorded.
Property DryRun As %Boolean [ InitialExpression = 1 ];

/// Where a decision held for a person goes to become a Workflow task. Blank: no task.
Property ReviewTarget As Ens.DataType.ConfigName [ InitialExpression = "Medic.Review" ];

Parameter SETTINGS = "AgentTarget:Basic,ReviewTarget:Basic,AutoApplyThreshold:Policy,AutoApplyMaxSeverity:Policy,DryRun:Policy";

XData BPL [ XMLNamespace = "http://www.intersystems.com/bpl" ]
{
<process language='objectscript' request='Medic.Msg.FailedMessage' response='Medic.Msg.Decision' height='2000' width='2000' >
<context>
<property name='Decision' type='Medic.Msg.Decision' instantiate='0' />
</context>
<sequence xend='200' yend='550' >
<call name='Ask agent' target='@process.AgentTarget' async='0' xpos='200' ypos='250' >
<request type='Medic.Msg.FailedMessage' >
<assign property="callrequest" value="request" action="set" />
</request>
<response type='Medic.Msg.Decision' >
<assign property="context.Decision" value="callresponse" action="set" />
</response>
</call>
<code name='Apply policy' xpos='200' ypos='350' >
<![CDATA[ do response.CopyFrom(context.Decision)
 set response.AutoApplied = ##class(Medic.Policy.AutoApply).CanAutoApply(response, process.AutoApplyThreshold, process.DryRun, process.AutoApplyMaxSeverity)
 do response.AddPolicyStep(process.AutoApplyThreshold, process.DryRun, process.AutoApplyMaxSeverity)
 // Held for a person: also a Workflow task (sent without waiting; the reviewer may answer much later).
 if 'response.AutoApplied && (process.ReviewTarget '= "") {
   do process.SendRequestAsync(process.ReviewTarget, ##class(Medic.Msg.ReviewRequest).From(response), 0)
 }]]>
</code>
</sequence>
</process>
}

}
