"""Drip-feed case files into the running production, like a morning's worth of failed messages.

Copies cases from data/cases into data/in (the Medic.DemoFeed folder) at a steady rate, in a
shuffled mix of all corruption types. Each file is written under a temporary name and renamed,
so the file adapter never picks up a half-written file.

    python dataset/feed.py                       # 20 cases, 1 per second
    python dataset/feed.py --count 100 --rate 5  # faster, for a busy-day demo
    python dataset/feed.py --only outage_critical_result,patient_mismatch
"""

from __future__ import annotations

import argparse
import os
import random
import shutil
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def pick(cases: list[Path], count: int, only: set[str], seed: int | None) -> list[Path]:
    if only:
        cases = [c for c in cases if c.name.rsplit("-", 2)[0] in only]
    if not cases:
        raise SystemExit("no matching case files; run dataset/generate.py --cases-dir data/cases first")
    rng = random.Random(seed)
    return [rng.choice(cases) for _ in range(count)] if count > len(cases) else rng.sample(cases, count)


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cases", type=Path, default=ROOT / "data/cases")
    ap.add_argument("--inbox", type=Path, default=ROOT / "data/in")
    ap.add_argument("--count", type=int, default=20)
    ap.add_argument("--rate", type=float, default=1.0, help="cases per second")
    ap.add_argument("--only", default="", help="comma-separated corruption types")
    ap.add_argument("--seed", type=int)
    args = ap.parse_args(argv)

    chosen = pick(sorted(args.cases.glob("*.json")), args.count, {s for s in args.only.split(",") if s}, args.seed)
    args.inbox.mkdir(parents=True, exist_ok=True)
    for i, case in enumerate(chosen, 1):
        # A unique name per drop, so the same case can be fed twice without clashing.
        name = f"{case.stem}-{time.time_ns()}.json"
        tmp = args.inbox / f".{name}.tmp"
        shutil.copyfile(case, tmp)
        os.replace(tmp, args.inbox / name)
        print(f"[{i}/{len(chosen)}] {case.stem}", flush=True)
        if i < len(chosen):
            time.sleep(1 / args.rate)


if __name__ == "__main__":
    main()
