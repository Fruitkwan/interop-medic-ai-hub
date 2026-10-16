/// An approved or corrected decision, searchable by similarity of its error text (IRIS Vector Search).
Class Medic.Data.Precedent Extends %Persistent
{

Property CaseId As %String(MAXLEN = 128);

Property ErrorText As %String(MAXLEN = 4000);

Property Summary As %String(MAXLEN = 1000);

Property Action As %String(MAXLEN = 32);

Property RerouteTarget As %String(MAXLEN = 128);

/// Who approved or corrected it.
Property DecidedBy As %String(MAXLEN = 64);

Property At As %TimeStamp;

Property Embedding As %Library.Vector(DATATYPE = "DOUBLE", LEN = 256);

Index EmbeddingIdx On (Embedding) As %SQL.Index.HNSW(Distance = "Cosine");

/// Store the final decision with the embedding of its error text.
ClassMethod Store(pDecision As Medic.Msg.Decision, pErrorText As %String, pSummary As %String, pDecidedBy As %String) As %Status
{
	set caseId = pDecision.CaseId, action = pDecision.Action, target = pDecision.RerouteTarget
	set vec = ##class(Medic.Data.Embed).Text(pErrorText)
	set at = $zdatetime($ztimestamp, 3, 1, 3)
	&sql(INSERT INTO Medic_Data.Precedent (CaseId, ErrorText, Summary, Action, RerouteTarget, DecidedBy, "At", Embedding)
		VALUES (:caseId, :pErrorText, :pSummary, :action, :target, :pDecidedBy, :at, TO_VECTOR(:vec, DOUBLE)))
	quit $select(SQLCODE < 0: $$$ERROR($$$GeneralError, "precedent insert failed: "_SQLCODE_" "_$get(%msg)), 1: $$$OK)
}

/// Most similar stored precedents, best first.
ClassMethod Search(pText As %String, pTop As %Integer = 3) As %DynamicArray
{
	set out = []
	set vec = ##class(Medic.Data.Embed).Text(pText)
	set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT TOP ? CaseId, Action, RerouteTarget, DecidedBy, Summary, VECTOR_COSINE(Embedding, TO_VECTOR(?, DOUBLE)) AS Sim FROM Medic_Data.Precedent ORDER BY Sim DESC", pTop, vec)
	while rs.%Next() {
		do out.%Push({"caseId": (rs.CaseId), "action": (rs.Action), "rerouteTarget": (rs.RerouteTarget), "decidedBy": (rs.DecidedBy), "similarity": (+rs.Sim), "summary": (rs.Summary)})
	}
	quit out
}

}
