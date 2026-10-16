/// Deterministic, keyless text embedding (hashed unigrams and bigrams) so vector search works in mock mode.
Class Medic.Data.Embed
{

Parameter DIM = 256;

/// 256-dimension L2-normalised vector as a comma-separated string, for TO_VECTOR(..., DOUBLE).
ClassMethod Text(pText As %String) As %String
{
	set text = $zconvert(pText, "L")
	set clean = ""
	for i = 1:1:$length(text) {
		set c = $extract(text, i)
		set clean = clean_$select(c ? 1AN: c, 1: " ")
	}
	set prev = ""
	for i = 1:1:$length(clean, " ") {
		set tok = $piece(clean, " ", i)
		if (tok = "") || (tok ? 1.N) { continue }
		set h = $zcrc(tok, 7) # ..#DIM
		set v(h) = $get(v(h)) + 1
		if prev '= "" {
			set b = $zcrc(prev_" "_tok, 7) # ..#DIM
			set v(b) = $get(v(b)) + 1
		}
		set prev = tok
	}
	set sum = 0
	set k = ""
	for { set k = $order(v(k), 1, n) quit:k=""  set sum = sum + (n * n) }
	set norm = $select(sum = 0: 1, 1: $zsqr(sum))
	set out = ""
	for i = 0:1:..#DIM - 1 {
		set out = out_$select(i: ",", 1: "")_($get(v(i)) / norm)
	}
	quit out
}

}
