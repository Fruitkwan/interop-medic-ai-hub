"""Record real runs of the live Medic API into the bundle the static public page replays.

    uv run python eval/record.py --batches 3 --out web/data/bundle.json

Switches the production to Jev + Gemini, triages every scenario and `--batches` batches of 5 random
cases, and always restores the models it found. A decision whose trace has an Agent step with value
"unavailable" (rate limit, outage) is retried twice after a 20 s pause and never written.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

RETRIES = 2
PAUSE_S = 20
TIMEOUT_S = 180


def _call(opener, base: str, method: str, path: str, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with opener(req, timeout=TIMEOUT_S) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _unavailable(decision: dict) -> bool:
    return any(s.get("stage") == "Agent" and s.get("value") == "unavailable" for s in decision.get("trace", []))


def record(base_url: str, batches: int, out: Path, opener=urllib.request.urlopen,
           fast: str = "Jev", agent: str = "Gemini", sleep=time.sleep, log=print) -> dict:
    """Record to `out` and return the bundle: {recordedAt, build, models, scenarios, batches}."""
    base = base_url.rstrip("/")
    api = lambda method, path, body=None: _call(opener, base, method, path, body)  # noqa: E731

    def triage(case: dict, name: str):
        """Triage with retries; None when the agent stays unavailable (never returns such a decision)."""
        for attempt in range(RETRIES + 1):
            decision = api("POST", "/triage", {"case": case})
            if not _unavailable(decision):
                return decision
            if attempt < RETRIES:
                log(f"  {name}: agent unavailable, retry {attempt + 1}/{RETRIES} in {PAUSE_S}s")
                sleep(PAUSE_S)
        log(f"  {name}: SKIPPED, agent still unavailable after {RETRIES} retries")
        return None

    found = api("GET", "/models")
    previous = {"fast": found["fast"], "agent": found["agent"]}
    skipped = 0
    try:
        used = api("POST", "/models", {"fast": fast, "agent": agent})
        health = api("GET", "/health")
        bundle = {
            "recordedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "build": health.get("build", ""),
            "models": {"fast": used["fast"], "agent": used["agent"]},
            "scenarios": [],
            "batches": [],
        }
        for s in api("GET", "/scenarios"):
            log(f"scenario {s['id']}")
            decision = triage(s["case"], s["id"])
            if decision is None:
                skipped += 1
                continue
            bundle["scenarios"].append({"id": s["id"], "label": s["label"], "case": s["case"], "decision": decision})
        for b in range(batches):
            batch = []
            for i, item in enumerate(api("GET", "/cases/random?n=5")):
                name = f"batch {b + 1} case {i + 1}"
                log(name)
                decision = triage(item["case"], name)
                if decision is None:
                    skipped += 1
                    continue
                batch.append({"case": item["case"], "expected": item["expected"], "decision": decision})
            bundle["batches"].append(batch)
    finally:
        api("POST", "/models", previous)

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(bundle, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    log(f"recorded {len(bundle['scenarios'])} scenarios and {sum(len(b) for b in bundle['batches'])} batch cases, "
        f"skipped {skipped}, models {bundle['models']} -> {out}")
    return bundle


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base", default="http://localhost:52773/medic/api")
    p.add_argument("--batches", type=int, default=3)
    p.add_argument("--out", type=Path, default=Path("web/data/bundle.json"))
    p.add_argument("--fast", default="Jev")
    p.add_argument("--agent", default="Gemini")
    args = p.parse_args()
    record(args.base, args.batches, args.out, fast=args.fast, agent=args.agent,
           log=lambda m: print(m, flush=True))


if __name__ == "__main__":
    sys.exit(main())
