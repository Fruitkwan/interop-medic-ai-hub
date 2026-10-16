"""API tests for the Medic REST layer. Needs the container running (mock models are selected by the tests).

Run: uv run python -m unittest tests/test_api.py -v
"""
import json
import unittest
import urllib.error
import urllib.request
import uuid

BASE = "http://localhost:52773/medic/api"


def call(method, path, body=None):
    """Return (status, raw bytes) for a request; HTTP errors are returned, not raised."""
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def call_json(method, path, body=None):
    status, raw = call(method, path, body)
    return status, json.loads(raw.decode("utf-8"))


def reachable():
    try:
        urllib.request.urlopen(BASE + "/health", timeout=5).read()
        return True
    except urllib.error.HTTPError:
        return True  # server is up but the route is missing: the tests must fail, not skip
    except Exception:
        return False


@unittest.skipUnless(reachable(), "Medic API not reachable at " + BASE + "/health (start the container)")
class ApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        status, _ = call_json("POST", "/models", {"fast": "Mock", "agent": "Mock"})
        assert status == 200, "could not switch models to Mock/Mock"
        _, cls.scenarios = call_json("GET", "/scenarios")

    def scenario(self, label):
        return next(s for s in self.scenarios if s["label"] == label)["case"]

    def fresh_case(self, label="Critical result"):
        case = dict(self.scenario(label))
        case["case_id"] = "API-" + uuid.uuid4().hex[:12]
        return case

    def triage(self, case):
        return call_json("POST", "/triage", {"case": case})

    def test_health(self):
        status, body = call_json("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["mode"], "live")
        self.assertIsInstance(body["aihub"], bool)
        self.assertTrue(body["build"])

    def test_scenarios_have_labels_and_ascii_names(self):
        self.assertGreaterEqual(len(self.scenarios), 4)
        labels = [s["label"] for s in self.scenarios]
        self.assertEqual(labels[:4], ["Endpoint timeout", "Critical result", "Misspelt receiver", "Wrong patient"])
        for s in self.scenarios:
            self.assertTrue(s["case"]["raw_message"].isascii(), s["id"])

    def test_triage_returns_trace(self):
        status, body = self.triage(self.fresh_case())
        self.assertEqual(status, 200, body)
        self.assertEqual(body["action"], "escalate")
        stages = [step["stage"] for step in body["trace"]]
        self.assertIn("Gate", stages)
        self.assertIn("Policy", stages)

    def test_triage_rejects_empty_message(self):
        case = self.fresh_case()
        case["raw_message"] = ""
        status, body = self.triage(case)
        self.assertEqual(status, 400)
        self.assertIn("error", body)

    def test_triage_rejects_bad_fhir(self):
        case = self.fresh_case()
        case["format"] = "fhir"
        case["raw_message"] = "{not json"
        status, body = self.triage(case)
        self.assertEqual(status, 400)
        self.assertIn("error", body)

    def test_triage_rejects_oversized(self):
        case = self.fresh_case()
        case["raw_message"] = "A" * 200000
        status, body = self.triage(case)
        self.assertEqual(status, 400)
        self.assertIn("error", body)

    def test_utf8_round_trip(self):
        case = self.fresh_case()
        segments = case["raw_message"].split("\r")
        segments = [("|".join(s.split("|")[:5] + ["Müller^José"] + s.split("|")[6:]) if s.startswith("PID|") else s)
                    for s in segments]
        case["raw_message"] = "\r".join(segments)
        self.assertIn("Müller^José", case["raw_message"])
        status, raw = call("POST", "/triage", {"case": case})
        self.assertEqual(status, 200, raw)
        text = raw.decode("utf-8")
        self.assertNotIn("�", text)
        self.assertEqual(json.loads(text)["caseId"], case["case_id"])

    def test_approve_then_conflict(self):
        status, d = self.triage(self.fresh_case())
        self.assertEqual(status, 200, d)
        status, body = call_json("POST", "/decisions/%s/approve" % d["id"], {})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["precedent"], 1)
        status, body = call_json("POST", "/decisions/%s/approve" % d["id"], {})
        self.assertEqual(status, 409)
        self.assertIn("error", body)

    def test_override_reroute_needs_target(self):
        status, d = self.triage(self.fresh_case())
        self.assertEqual(status, 200, d)
        status, body = call_json("POST", "/decisions/%s/override" % d["id"], {"action": "reroute"})
        self.assertEqual(status, 400)
        self.assertIn("error", body)

    def test_random_cases_clamped(self):
        status, body = call_json("GET", "/cases/random?n=50")
        self.assertEqual(status, 200)
        self.assertEqual(len(body), 10)
        for item in body:
            self.assertIn("action", item["expected"])

    def test_models_round_trip(self):
        status, body = call_json("GET", "/models")
        self.assertEqual(status, 200)
        self.assertEqual((body["fast"], body["agent"]), ("Mock", "Mock"))
        self.assertIn("Mock", body["available"]["fast"])
        self.assertIn("Mock", body["available"]["agent"])


if __name__ == "__main__":
    unittest.main()
