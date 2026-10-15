/// A failed or suspended interoperability message, plus the context the triage agent needs.
Class Medic.Msg.FailedMessage Extends Ens.Request
{

Property CaseId As %String(MAXLEN = 128);

Property Format As %String(VALUELIST = ",hl7v2,fhir");

Property RawMessage As %Stream.GlobalCharacter;

Property ErrorText As %String(MAXLEN = 4000);

/// JSON: routing_table, endpoint {name, up, down_minutes, last_error}, optional mpi / seen_control_ids.
/// The demo feed supplies it; against live traffic the BPL gather step builds it.
Property ContextJSON As %String(MAXLEN = "");

/// Ens.MessageHeader ID of the original failed message, when triaging live traffic.
Property OriginalHeaderId As %Integer;

/// Build from one case of dataset/generate.py (labels are never copied in).
ClassMethod FromCase(pCase As %DynamicObject) As Medic.Msg.FailedMessage
{
	set req = ..%New()
	set req.CaseId = pCase."case_id"
	set req.Format = pCase.format
	do req.RawMessage.Write(pCase."raw_message")
	set req.ErrorText = pCase."error_text"
	set req.ContextJSON = pCase.context.%ToJSON()
	quit req
}

}
