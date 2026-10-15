import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import score as s  # noqa: E402


def row(action, conf, expected, target=None, split="calibration"):
    d = {"action": action, "confidence": conf, "reroute_target": target}
    return {"final": d, "jev": d, "expected": {"action": expected, "reroute_target": None}, "split": split}


class ScoreTests(unittest.TestCase):
    def test_ucb_zero_errors_matches_closed_form(self):
        # k = 0: (1 - p)^n = delta  =>  p = 1 - delta^(1/n)
        self.assertAlmostEqual(s.risk_ucb(0, 114, 0.1), 1 - 0.1 ** (1 / 114), places=6)
        self.assertAlmostEqual(s.risk_ucb(0, 114, 0.1), 0.0200, places=3)

    def test_ucb_grows_with_errors_and_shrinks_with_n(self):
        self.assertLess(s.risk_ucb(1, 100, 0.1), s.risk_ucb(3, 100, 0.1))
        self.assertLess(s.risk_ucb(1, 400, 0.1), s.risk_ucb(1, 100, 0.1))
        self.assertEqual(s.risk_ucb(0, 0, 0.1), 1.0)

    def test_reroute_needs_the_right_target(self):
        exp = {"action": "reroute", "reroute_target": "Medic.To.LIS"}
        self.assertTrue(s.is_correct({"action": "reroute", "reroute_target": "Medic.To.LIS"}, exp))
        self.assertFalse(s.is_correct({"action": "reroute", "reroute_target": "Medic.To.EPR"}, exp))

    def test_escalations_are_never_auto_applied(self):
        rows = [row("escalate", 0.99, "resend")]
        self.assertEqual(s.auto_applied(rows, "final", 0.5), [])

    def test_calibrate_picks_lowest_passing_threshold(self):
        # 200 correct at 0.95, then 50 wrong at 0.80: passes down to 0.85, fails once 0.80 is included.
        rows = [row("resend", 0.95, "resend") for _ in range(200)] + [row("resend", 0.80, "escalate") for _ in range(50)]
        self.assertEqual(s.calibrate(rows, "final", alpha=0.05, delta=0.1), 0.85)

    def test_small_group_at_the_top_does_not_block_lower_thresholds(self):
        rows = [row("quarantine", 0.95, "quarantine") for _ in range(10)] + [row("resend", 0.90, "resend") for _ in range(300)]
        self.assertEqual(s.calibrate(rows, "final", alpha=0.05, delta=0.1), 0.5)

    def test_calibrate_none_when_too_few_cases(self):
        rows = [row("resend", 0.95, "resend") for _ in range(10)]
        self.assertIsNone(s.calibrate(rows, "final", alpha=0.02, delta=0.1))


if __name__ == "__main__":
    unittest.main()
