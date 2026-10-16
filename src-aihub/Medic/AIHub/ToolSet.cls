Class Medic.AIHub.ToolSet Extends %AI.ToolSet [ DependsOn = Medic.AIHub.Tools ]
{

XData Definition [ MimeType = application/xml ]
{
<ToolSet Name="MedicTriage">
  <Description>Read-only checks for triaging failed interoperability messages.</Description>
  <Include Class="Medic.AIHub.Tools" />
</ToolSet>
}

}
