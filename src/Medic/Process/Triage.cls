/// Triage one failed message: ask the agent, apply the auto-apply policy, reply.
Class Medic.Process.Triage Extends Ens.BusinessProcessBPL
{

Property AgentTarget As Ens.DataType.ConfigName [ InitialExpression = "Medic.Agent" ];

/// Minimum confidence to apply a decision without a human.
Property AutoApplyThreshold As %Numeric [ InitialExpression = 0.9 ];

/// When on, nothing is applied; every decision is only recorded.
Property DryRun As %Boolean [ InitialExpression = 1 ];

Parameter SETTINGS = "AgentTarget:Basic,AutoApplyThreshold:Policy,DryRun:Policy";

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
 set response.AutoApplied = ##class(Medic.Policy.AutoApply).CanAutoApply(response, process.AutoApplyThreshold, process.DryRun)]]>
</code>
</sequence>
</process>
}

}
