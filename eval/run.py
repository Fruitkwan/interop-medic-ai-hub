"""Run the eval end to end: push every dataset case through the running IRIS production, then score.

    docker compose up -d
    python eval/run.py              # all cases
    python eval/run.py --limit 20   # quick smoke run
"""

from __future__ import annotations

import argparse
import subprocess
import sys

import score


def run_in_iris(container: str, split: str, limit: int) -> None:
    script = (
        f' set sc=##class(Medic.Eval.Runner).Run("/dataset/cases.jsonl","/data/results/results.jsonl","{split}",{limit})\n'
        " if 'sc do $system.Status.DisplayError(sc)\n"
        " halt\n"
    )
    proc = subprocess.run(["docker", "exec", "-i", container, "iris", "session", "IRIS", "-U", "USER"],
                          input=script, text=True, capture_output=True)
    out = proc.stdout + proc.stderr
    if "evaluated" not in out:
        sys.exit(f"eval run failed in IRIS:\n{out[-3000:]}")
    print(next(line for line in out.splitlines() if "evaluated" in line).strip())


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--container", default="interop-medic")
    ap.add_argument("--split", default="", help="calibration, test, or empty for both")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--delta", type=float, default=0.1)
    args = ap.parse_args()

    run_in_iris(args.container, args.split, args.limit)
    score.main(["--delta", str(args.delta)])


if __name__ == "__main__":
    main()
