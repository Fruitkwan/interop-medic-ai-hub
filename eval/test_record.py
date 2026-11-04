"""Tests for record.py with a fake opener serving canned API responses.

Run: uv run python -m unittest eval/test_record.py -v
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import record  # noqa: E402


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def read(self):
        return json.dumps(self.payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def decision(case_id, agent_value="escalate 0.9"):
    return {
        "id": case_id, "caseId": case_id, "action": "escalate", "trace": [
            {"stage": "Jev", "status": "ok", "value": "resend 0.5", "detail": "", "ms": 1},
            {"stage": "Agent", "status": "ok" if agent_value != "unavailable" else "bad",
             "value": agent_value, "detail": "", "ms": 2},
        ], "audit": [],
    }


class FakeApi:
    """Routes calls by method and path; `flaky` maps a case_id to how many unavailable replies first."""

    def __init__(self, flaky=None, always_down=()):
        self.models = {"fast": "Mock", "agent": "Mock"}
        self.calls = []
        self.flaky = dict(flaky or {})
        self.always_down = set(always_down)
        self.triaged = []

    def __call__(self, req, timeout=None):
        method, url = req.get_method(), req.full_url
        path = url.split("/medic/api", 1)[1]
        body = json.loads(req.data) if req.data else None
        self.calls.append((method, path))
        if path == "/health":
            return FakeResponse({"mode": "live", "aihub": True, "build": "2026.3.0AI"})
        if path == "/models" and method == "GET":
            return FakeResponse({**self.models, "available": {}})
        if path == "/models":
            self.models = {"fast": body["fast"], "agent": body["agent"]}
            return FakeResponse({**self.models, "available": {}})
        if path == "/scenarios":
            return FakeResponse([{"id": f"s{i}", "label": f"Scenario {i}", "case": {"case_id": f"s{i}-case"}}
                                 for i in range(3)])
        if path.startswith("/cases/random"):
            return FakeResponse([{"case": {"case_id": f"r{len(self.calls)}-{i}"}, "expected": {"action": "resend"}}
                                 for i in range(5)])
        if path == "/triage":
            cid = body["case"]["case_id"]
            self.triaged.append(cid)
            if cid in self.always_down or self.flaky.get(cid, 0) > 0:
                self.flaky[cid] = self.flaky.get(cid, 0) - 1
                return FakeResponse(decision(cid, "unavailable"))
            return FakeResponse(decision(cid))
        raise AssertionError(f"unexpected call {method} {path}")


class RecordTest(unittest.TestCase):
    def run_record(self, api, batches=2, **kw):
        sleeps = []
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "nested" / "bundle.json"
            bundle = record.record("http://x/medic/api", batches, out, opener=api, sleep=sleeps.append, **kw)
            on_disk = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(bundle, on_disk)
        return bundle, sleeps

    def test_bundle_shape(self):
        api = FakeApi()
        bundle, sleeps = self.run_record(api)
        self.assertEqual(set(bundle), {"recordedAt", "build", "models", "scenarios", "batches"})
        self.assertEqual(bundle["build"], "2026.3.0AI")
        self.assertEqual(bundle["models"], {"fast": "Jev", "agent": "Gemini"})
        self.assertEqual([s["id"] for s in bundle["scenarios"]], ["s0", "s1", "s2"])
        self.assertEqual(set(bundle["scenarios"][0]), {"id", "label", "case", "expected", "decision"})
        self.assertEqual(sleeps, [])

    def test_batches_of_five(self):
        bundle, _ = self.run_record(FakeApi(), batches=2)
        self.assertEqual([len(b) for b in bundle["batches"]], [5, 5])
        self.assertEqual(set(bundle["batches"][0][0]), {"case", "expected", "decision"})

    def test_models_switched_and_restored(self):
        api = FakeApi()
        self.run_record(api)
        self.assertEqual(api.models, {"fast": "Mock", "agent": "Mock"})
        posts = [c for c in api.calls if c == ("POST", "/models")]
        self.assertEqual(len(posts), 2)

    def test_models_restored_on_failure(self):
        api = FakeApi()
        orig = api.__call__

        def boom(req, timeout=None):
            if req.full_url.endswith("/scenarios"):
                raise OSError("down")
            return orig(req, timeout)

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(OSError):
                record.record("http://x/medic/api", 1, Path(tmp) / "b.json", opener=boom, sleep=lambda s: None)
        self.assertEqual(api.models, {"fast": "Mock", "agent": "Mock"})

    def test_unavailable_is_retried_then_recorded_clean(self):
        api = FakeApi(flaky={"s1-case": 2})
        bundle, sleeps = self.run_record(api, batches=0)
        self.assertEqual(api.triaged.count("s1-case"), 3)
        self.assertEqual(sleeps, [20, 20])
        self.assertEqual(len(bundle["scenarios"]), 3)
        for s in bundle["scenarios"]:
            self.assertNotIn("unavailable", [st["value"] for st in s["decision"]["trace"]])

    def test_persistent_unavailable_is_skipped_not_written(self):
        api = FakeApi(always_down={"s1-case"})
        bundle, sleeps = self.run_record(api, batches=0, allow_partial=True)
        self.assertEqual(api.triaged.count("s1-case"), 3)
        self.assertEqual(sleeps, [20, 20])
        self.assertEqual([s["id"] for s in bundle["scenarios"]], ["s0", "s2"])
        self.assertNotIn("unavailable", json.dumps(bundle))

    def test_incomplete_run_leaves_existing_bundle_untouched(self):
        api = FakeApi(always_down={"s1-case"})
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bundle.json"
            out.write_bytes(b'{"good":"bundle"}')
            with self.assertRaises(record.PartialRecording):
                record.record("http://x/medic/api", 1, out, opener=api, sleep=lambda s: None, log=lambda m: None)
            self.assertEqual(out.read_bytes(), b'{"good":"bundle"}')
            partial = json.loads((Path(tmp) / "bundle.partial.json").read_text(encoding="utf-8"))
            self.assertEqual([s["id"] for s in partial["scenarios"]], ["s0", "s2"])
            self.assertEqual([p.name for p in Path(tmp).iterdir() if p.name.endswith(".tmp")], [])
        self.assertEqual(api.models, {"fast": "Mock", "agent": "Mock"})

    def test_empty_run_is_partial(self):
        class Dead(FakeApi):
            def __init__(self):
                super().__init__(always_down={"s0-case", "s1-case", "s2-case"})
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bundle.json"
            with self.assertRaises(record.PartialRecording):
                record.record("http://x/medic/api", 0, out, opener=Dead(), sleep=lambda s: None, log=lambda m: None)
            self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
