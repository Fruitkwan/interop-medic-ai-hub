/// Unit tests for the auto-apply policy.
/// Run: do ##class(%UnitTest.Manager).DebugRunTestCase("", "Medic.Test.Policy", "", "")
Class Medic.Test.Policy Extends %UnitTest.TestCase
{

ClassMethod Decision(pAction As %String, pConfidence As %Numeric, pSeverity As %Numeric) As Medic.Msg.Decision
{
	set d = ##class(Medic.Msg.Decision).%New()
	set d.Action = pAction, d.Confidence = pConfidence, d.Severity = pSeverity
	quit d
}

Method TestConfidentAndMildRunsAlone()
{
	do $$$AssertTrue(##class(Medic.Policy.AutoApply).CanAutoApply(..Decision("resend", 0.95, 0.3), 0.9, 0))
}

/// The recorded miss: Gemma resent a critical result at confidence 0.9, severity 0.6.
Method TestSevereWaitsHoweverConfident()
{
	set p = "Medic.Policy.AutoApply"
	do $$$AssertNotTrue($classmethod(p, "CanAutoApply", ..Decision("resend", 0.9, 0.6), 0.9, 0), "the limit itself is held")
	do $$$AssertNotTrue($classmethod(p, "CanAutoApply", ..Decision("fix_and_resend", 1, 0.8), 0.9, 0))
	do $$$AssertTrue($classmethod(p, "CanAutoApply", ..Decision("resend", 0.95, 0.59), 0.9, 0), "just under the limit")
	do $$$AssertTrue($classmethod(p, "CanAutoApply", ..Decision("resend", 0.95, 0.7), 0.9, 0, 0.8), "the limit is a setting")
}

Method TestOtherHolds()
{
	set p = "Medic.Policy.AutoApply"
	do $$$AssertNotTrue($classmethod(p, "CanAutoApply", ..Decision("resend", 0.89, 0.1), 0.9, 0), "below the threshold")
	do $$$AssertNotTrue($classmethod(p, "CanAutoApply", ..Decision("escalate", 1, 0), 0.9, 0), "an escalation never runs alone")
	do $$$AssertNotTrue($classmethod(p, "CanAutoApply", ..Decision("resend", 1, 0), 0.9, 1), "dry run")
	do $$$AssertNotTrue($classmethod(p, "CanAutoApply", "", 0.9, 0), "no decision")
}

Method TestPolicyStepNamesTheLimit()
{
	set d = ..Decision("resend", 0.9, 0.6)
	do d.AddPolicyStep(0.9, 0, 0.6)
	do $$$AssertTrue(d.Steps().%Get(0).detail [ "severity limit .6", d.Steps().%Get(0).detail)
}

}
