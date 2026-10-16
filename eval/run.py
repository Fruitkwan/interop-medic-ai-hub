"""Run the eval end to end: push every dataset case through the running IRIS production, then score.

    docker compose up -d
    uv run python eval/run.py                  # all cases, results in data/results/<provider tag>/
    uv run python eval/run.py --limit 20       # quick smoke run
    uv run python eval/run.py --tag laya-local # name the run, e.g. to compare fast-tier providers
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

import score


def iris(container: str, script: str) -> str:
    proc = subprocess.run(["docker", "exec", "-i", container, "iris", "session", "IRIS", "-U", "USER"],
                          input=script, text=True, capture_output=True)
    return proc.stdout + proc.stderr


def fast_provider(container: str) -> str:
    """The provider the fast tier is configured with, as the default run tag."""
    out = iris(container, ' write "PROVIDER=",##class(Medic.Operation.FastTier).Pick('
                          '##class(Ens.Director).GetHostSettingValue("Medic.FastTier","ProviderClass"),'
                          '"MEDIC_FAST_PROVIDER","Medic.Provider.JevMock"),!\n halt\n')
    m = re.search(r"PROVIDER=(\S+)", out)
    return m.group(1).rsplit(".", 1)[-1].lower() if m else "run"


def run_in_iris(container: str, out_path: str, split: str, limit: int) -> None:
    out = iris(container,
               f' set sc=##class(Medic.Eval.Runner).Run("/dataset/cases.jsonl","{out_path}","{split}",{limit})\n'
               " if 'sc do $system.Status.DisplayError(sc)\n"
               " halt\n")
    if "evaluated" not in out:
        sys.exit(f"eval run failed in IRIS:\n{out[-3000:]}")
    print(next(line for line in out.splitlines() if "evaluated" in line).strip())


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--container", default="interop-medic")
    ap.add_argument("--tag", help="results folder name; defaults to the fast-tier provider")
    ap.add_argument("--split", default="", help="calibration, test, or empty for both")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--delta", type=float, default=0.1)
    args = ap.parse_args()

    tag = args.tag or fast_provider(args.container)
    run_in_iris(args.container, f"/data/results/{tag}/results.jsonl", args.split, args.limit)
    out_dir = score.ROOT / "data/results" / tag
    score.main(["--delta", str(args.delta), "--results", str(out_dir / "results.jsonl"), "--out", str(out_dir)])


if __name__ == "__main__":
    main()
