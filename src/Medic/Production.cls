Class Medic.Production Extends Ens.Production
{

XData ProductionDefinition
{
<Production Name="Medic.Production" LogGeneralTraceEvents="false">
  <Description>Interop Medic: an agent that triages failed interoperability messages</Description>
  <ActorPoolSize>2</ActorPoolSize>
  <Item Name="Medic.DemoFeed" Category="Demo" ClassName="Medic.Service.DemoFeed" PoolSize="1" Enabled="true">
    <Setting Target="Adapter" Name="FilePath">/data/in/</Setting>
    <Setting Target="Adapter" Name="FileSpec">*.json</Setting>
    <Setting Target="Adapter" Name="ArchivePath">/data/done/</Setting>
    <Setting Target="Host" Name="TargetConfigName">Medic.Triage</Setting>
  </Item>
  <Item Name="Medic.Eval" Category="Eval" ClassName="Medic.Eval.Service" PoolSize="0" Enabled="true">
  </Item>
  <Item Name="Medic.Triage" Category="" ClassName="Medic.Process.Triage" PoolSize="1" Enabled="true">
  </Item>
  <Item Name="Medic.Agent" Category="" ClassName="Medic.Operation.Agent" PoolSize="1" Enabled="true">
  </Item>
  <Item Name="Medic.Jev" Category="" ClassName="Medic.Operation.Jev" PoolSize="1" Enabled="true">
  </Item>
</Production>
}

}
