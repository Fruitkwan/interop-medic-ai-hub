"""Record real runs of the live Medic API into the bundle the static public page replays.

    uv run python eval/record.py --batches 3 --out web/data/bundle.json

Switches the production to Jev + Gemini, triages every scenario and `--batches` batches of 5 random
cases, and always restores the models it found. A decision whose trace has an Agent step with value
"unavailable" (rate limit, outage) is retried twice after a 20 s pause and never written.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

RETRIES = 2
PAUSE_S = 20
TIMEOUT_S = 180


def _call(opener, base: str, method: str, path: str, body=None, timeout: float = TIMEOUT_S):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with opener(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


class PartialRecording(Exception):
    """The run skipped items or fell short of the bundle schema; `out` was left untouched."""

    def __init__(self, message: str, partial: Path):
        super().__init__(message)
        self.partial = partial


def _write_atomic(path: Path, text: str) -> None:
    """Write via a temp file in the same directory, then replace, so a crash never leaves half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _unavailable(decision: dict) -> bool:
    return any(s.get("stage") == "Agent" and s.get("value") == "unavailable" for s in decision.get("trace", []))


def record(base_url: str, batches: int, out: Path, opener=urllib.request.urlopen,
           fast: str = "Jev", agent: str = "Gemini", sleep=time.sleep, log=print,
           allow_partial: bool = False, timeout: float = TIMEOUT_S) -> dict:
    """Record to `out` and return the bundle: {recordedAt, build, models, scenarios, batches}."""
    base = base_url.rstrip("/")
    api = lambda method, path, body=None: _call(opener, base, method, path, body, timeout)  # noqa: E731

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

    text = json.dumps(bundle, ensure_ascii=False, separators=(",", ":"))
    n_cases = sum(len(b) for b in bundle["batches"])
    log(f"recorded {len(bundle['scenarios'])} scenarios and {n_cases} batch cases, "
        f"skipped {skipped}, models {bundle['models']}")
    complete = (skipped == 0 and bundle["scenarios"] and len(bundle["batches"]) == batches
                and all(len(b) == 5 for b in bundle["batches"]))
    if complete or allow_partial:
        _write_atomic(out, text)
        log(f"wrote {out}")
        return bundle
    partial = out.with_suffix(".partial.json")
    _write_atomic(partial, text)
    raise PartialRecording(f"incomplete run ({skipped} skipped); {out} left untouched, partial run in {partial}", partial)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base", default="http://localhost:52773/medic/api")
    p.add_argument("--batches", type=int, default=3)
    p.add_argument("--out", type=Path, default=Path("web/data/bundle.json"))
    p.add_argument("--fast", default="Jev")
    p.add_argument("--agent", default="Gemini")
    p.add_argument("--timeout", type=float, default=TIMEOUT_S,
                   help="seconds to wait for one triage (a local model on a CPU needs several minutes)")
    p.add_argument("--allow-partial", action="store_true", help="write the bundle even if cases were skipped")
    args = p.parse_args()
    try:
        record(args.base, args.batches, args.out, fast=args.fast, agent=args.agent,
               log=lambda m: print(m, flush=True), allow_partial=args.allow_partial, timeout=args.timeout)
    except PartialRecording as e:
        sys.exit(f"ERROR: {e}")


if __name__ == "__main__":
    sys.exit(main())
