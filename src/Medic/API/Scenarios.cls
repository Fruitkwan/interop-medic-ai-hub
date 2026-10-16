/// Dataset cases for the web page: one scenario per corruption type, and random labelled cases.
Class Medic.API.Scenarios
{

Parameter DATASET = "/dataset/cases.jsonl";

/// These corruption types come first, in this order.
Parameter FEATURED = "endpoint_timeout,outage_critical_result,unknown_receiver,patient_mismatch";

/// [{"id","label","case"}] one per corruption type: the first case with an ASCII raw_message, featured types first.
ClassMethod List() As %DynamicArray
{
	kill first, order
	set n = 0
	set in = ..Open()
	while 'in.AtEnd {
		set line = in.ReadLine(1000000)
		continue:line=""
		set case = {}.%FromJSON(line)
		set type = case.corruption
		continue:$data(first(type))
		continue:'..IsAscii(case."raw_message")
		set first(type) = case, n = n + 1, order(n) = type
	}
	set out = []
	for i = 1:1:$length(..#FEATURED, ",") {
		set type = $piece(..#FEATURED, ",", i)
		do:$data(first(type)) out.%Push(..Entry(type, first(type)))
	}
	for i = 1:1:n {
		set type = order(i)
		do:'$listfind($listfromstring(..#FEATURED), type) out.%Push(..Entry(type, first(type)))
	}
	quit out
}

/// [{"case","expected"}] n random cases, n clamped to 1-10.
ClassMethod Random(pN As %Integer = 5) As %DynamicArray
{
	set pN = $select(pN < 1: 1, pN > 10: 10, 1: pN \ 1)
	kill lines
	set total = 0
	set in = ..Open()
	while 'in.AtEnd {
		set line = in.ReadLine(1000000)
		continue:line=""
		set lines($increment(total)) = line
	}
	set pN = $select(pN > total: total, 1: pN)
	set out = []
	while out.%Size() < pN {
		set pick = $random(total) + 1
		continue:$data(used(pick))
		set used(pick) = 1
		set case = {}.%FromJSON(lines(pick))
		set expected = case.expected
		do case.%Remove("expected")
		do out.%Push({"case": (case), "expected": (expected)})
	}
	quit out
}

ClassMethod Entry(pType As %String, pCase As %DynamicObject) As %DynamicObject [ Private ]
{
	do pCase.%Remove("expected")
	quit {"id": (pType), "label": (..Label(pType)), "case": (pCase)}
}

ClassMethod Label(pType As %String) As %String
{
	quit $case(pType,
		"endpoint_timeout": "Endpoint timeout",
		"outage_critical_result": "Critical result",
		"unknown_receiver": "Misspelt receiver",
		"patient_mismatch": "Wrong patient",
		: $zconvert($extract(pType), "U")_$translate($extract(pType, 2, *), "_", " "))
}

ClassMethod IsAscii(pText As %String) As %Boolean
{
	quit $length(pText) = $length($zconvert(pText, "O", "UTF8"))
}

ClassMethod Open() As %Stream.FileCharacter [ Private ]
{
	set in = ##class(%Stream.FileCharacter).%New()
	set in.TranslateTable = "UTF8", in.LineTerminator = $char(10)
	$$$ThrowOnError(in.LinkToFile(..#DATASET))
	quit in
}

}
