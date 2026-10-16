/// Runs dataset cases through the live production and writes one JSON line per case with the
/// full pipeline's decision and, for comparison, the fast tier's decision alone.
/// Scoring and threshold calibration happen in eval/score.py.
Class Medic.Eval.Runner
{

ClassMethod Run(pCases As %String = "/dataset/cases.jsonl", pOut As %String = "/data/results/results.jsonl", pSplit As %String = "", pLimit As %Integer = 0) As %Status
{
	set sc = $$$OK
	try {
		$$$ThrowOnError(##class(Ens.Director).CreateBusinessService("Medic.Eval", .svc))
		do ##class(%File).CreateDirectoryChain(##class(%File).GetDirectory(pOut))

		set in = ##class(%Stream.FileCharacter).%New()
		set in.TranslateTable = "UTF8", in.LineTerminator = $char(10)
		$$$ThrowOnError(in.LinkToFile(pCases))
		set out = ##class(%Stream.FileCharacter).%New()
		set out.TranslateTable = "UTF8", out.LineTerminator = $char(10)
		$$$ThrowOnError(out.LinkToFile(pOut))
		do out.Clear()

		set n = 0
		while 'in.AtEnd {
			set line = in.ReadLine(1000000)
			continue:line=""
			set case = {}.%FromJSON(line)
			continue:(pSplit '= "")&&(case.split '= pSplit)

			set target = "Medic.Triage"
			$$$ThrowOnError(svc.ProcessInput(##class(Medic.Msg.FailedMessage).FromCase(case), .final, .target))
			set target = "Medic.FastTier"
			$$$ThrowOnError(svc.ProcessInput(##class(Medic.Msg.FailedMessage).FromCase(case), .fast, .target))

			do out.WriteLine({"case_id": (case."case_id"), "final": (..AsJSON(final)), "fast": (..AsJSON(fast))}.%ToJSON())
			set n = n + 1
			quit:(pLimit > 0)&&(n >= pLimit)
		}
		$$$ThrowOnError(out.%Save())
		write "evaluated ", n, " cases -> ", pOut, !
	} catch ex {
		set sc = ex.AsStatus()
	}
	quit sc
}

ClassMethod AsJSON(d As Medic.Msg.Decision) As %DynamicObject
{
	quit {
		"action": (d.Action), "confidence": (+d.Confidence), "severity": (+d.Severity),
		"decided_by": (d.DecidedBy), "reroute_target": (d.RerouteTarget), "provider": (d.Provider),
		"auto_applied": (''d.AutoApplied), "latency_ms": (+d.LatencyMs), "cost_usd": (+d.CostUSD),
		"trace": (d.Steps())
	}
}

}
