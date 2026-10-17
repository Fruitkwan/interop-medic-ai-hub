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

/// Models the web page chose for this one message (labels from GET /models); blank means the
/// production's own settings. Lets each judge pick models without switching them for everyone.
Property FastModel As %String(MAXLEN = 64);

Property AgentModel As %String(MAXLEN = 64);

/// Token for the judge's own API keys (Medic.API.Keys), valid only while this request runs.
/// The keys themselves are never in the message.
Property KeyToken As %String(MAXLEN = 64);

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
