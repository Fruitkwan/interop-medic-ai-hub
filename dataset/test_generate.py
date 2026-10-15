import json
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import generate as g  # noqa: E402


class GenerateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cases = g.generate(n_per_type=20, seed=11)

    def test_deterministic_for_seed(self):
        self.assertEqual(self.cases, g.generate(n_per_type=20, seed=11))
        self.assertNotEqual(self.cases, g.generate(n_per_type=20, seed=12))

    def test_every_corruption_has_n_cases_and_unique_ids(self):
        counts = Counter(c["corruption"] for c in self.cases)
        self.assertEqual(set(counts), set(g.CORRUPTIONS))
        self.assertEqual(counts, {k: 20 * g.WEIGHTS.get(k, 1) for k in g.CORRUPTIONS})
        self.assertEqual(len({c["case_id"] for c in self.cases}), len(self.cases))

    def test_labels_are_valid(self):
        for c in self.cases:
            e = c["expected"]
            self.assertIn(e["action"], g.ACTIONS, c["case_id"])
            self.assertTrue(0.0 <= e["severity"] <= 1.0, c["case_id"])
            self.assertTrue(c["synthetic"])
            self.assertEqual(e["reroute_target"] is not None, e["action"] == "reroute", c["case_id"])

    def test_all_actions_represented(self):
        self.assertEqual({c["expected"]["action"] for c in self.cases}, set(g.ACTIONS))

    def test_fix_cases_carry_a_different_fixed_message(self):
        for c in self.cases:
            if c["expected"]["action"] == "fix_and_resend":
                self.assertTrue(c["expected"]["fixed_message"])
                self.assertNotEqual(c["raw_message"], c["expected"]["fixed_message"], c["case_id"])

    def test_hl7_shape(self):
        for c in self.cases:
            if c["format"] == "hl7v2":
                self.assertTrue(c["raw_message"].startswith("MSH|^~\\&|"), c["case_id"])
                if c["corruption"] != "truncated":
                    self.assertIn("\rPID|", c["raw_message"], c["case_id"])

    def test_fhir_is_json(self):
        for c in self.cases:
            if c["format"] == "fhir":
                json.loads(c["raw_message"])

    def test_ambiguous_dates_are_really_ambiguous(self):
        for c in self.cases:
            if c["corruption"] == "ambiguous_date":
                day, month, _ = c["raw_message"].split("\rPID|")[1].split("|")[6].split("/")
                self.assertLessEqual(int(day), 12)
                self.assertNotEqual(day, month)

    def test_same_error_different_action(self):
        # Timeout text alone must not decide the action - context (critical result, outage length) does.
        crit = [c for c in self.cases if c["corruption"] == "outage_critical_result"]
        self.assertTrue(all("OBX|" in c["raw_message"] and ("|HH|" in c["raw_message"] or "|LL|" in c["raw_message"])
                            for c in crit))
        self.assertTrue(all(c["context"]["endpoint"]["down_minutes"] >= 180 for c in crit))

    def test_split_roughly_matches_share(self):
        share = sum(c["split"] == "calibration" for c in self.cases) / len(self.cases)
        self.assertGreater(share, 0.45)
        self.assertLess(share, 0.75)

    def test_cli_writes_jsonl_and_case_files(self):
        with tempfile.TemporaryDirectory() as d:
            out, cases_dir = Path(d) / "cases.jsonl", Path(d) / "in"
            g.main(["--n-per-type", "2", "--out", str(out), "--cases-dir", str(cases_dir)])
            lines = out.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), sum(2 * g.WEIGHTS.get(k, 1) for k in g.CORRUPTIONS))
            self.assertEqual(len(list(cases_dir.glob("*.json"))), len(lines))


class LabTests(unittest.TestCase):
    def test_critical_values_are_past_the_critical_limit(self):
        rng = g.random.Random(1)
        for code in g.CRITICAL_CODES:
            _, _, _, _, clo, chi = g.LABS[code]
            for _ in range(50):
                lab = g.make_lab(rng, code, critical=True)
                self.assertTrue(lab.value < clo or lab.value > chi, (code, lab.value))
                self.assertIn(lab.flag, ("LL", "HH"))

    def test_flags_follow_ranges(self):
        rng = g.random.Random(1)
        self.assertEqual(g.make_lab(rng, "6298-4", 4.2).flag, "N")
        self.assertEqual(g.make_lab(rng, "6298-4", 5.6).flag, "H")
        self.assertEqual(g.make_lab(rng, "6298-4", 2.1).flag, "LL")


SAMPLE = Path(__file__).with_name("synthea")


@unittest.skipUnless((SAMPLE / "patients.csv").exists(), "no Synthea sample")
class SyntheaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = g.SyntheaSource(SAMPLE)
        cls.cases = g.generate(n_per_type=10, seed=3, source=cls.src)

    def test_deterministic(self):
        self.assertEqual(self.cases, g.generate(n_per_type=10, seed=3, source=g.SyntheaSource(SAMPLE)))

    def test_patients_come_from_the_sample(self):
        names = {f"{p.family}^{p.given}" for p in self.src.patients}
        for c in self.cases:
            if c["format"] == "hl7v2" and c["corruption"] != "truncated":
                pid = c["raw_message"].split("\rPID|")[1].split("|")
                self.assertIn(pid[4], names, c["case_id"])
            self.assertEqual(c["patients"], "synthea")

    def test_mrn_is_stable_per_patient(self):
        p = self.src.patients[0]
        self.assertEqual(p.mrn, g.SyntheaSource.mrn(p.source_id))
        self.assertRegex(p.mrn, r"^\d{8}$")

    def test_normal_results_are_real_sample_values(self):
        sample_values = {(code, v) for labs in self.src.labs.values() for code, v in labs}
        for c in self.cases:
            if c["corruption"] in ("endpoint_timeout", "patient_mismatch"):
                obx = c["raw_message"].split("\rOBX|")[1].split("|")
                code, value = obx[2].split("^")[0], float(obx[4])
                self.assertIn((code, value), sample_values, c["case_id"])

    def test_all_actions_still_represented(self):
        self.assertEqual({c["expected"]["action"] for c in self.cases}, set(g.ACTIONS))


if __name__ == "__main__":
    unittest.main()
