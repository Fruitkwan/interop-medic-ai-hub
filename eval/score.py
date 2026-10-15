"""Score Interop Medic eval results and calibrate the auto-apply threshold.

Reads the runner output (one line per case: the full pipeline's decision and Jev's alone) plus the
labelled dataset, then reports:

1. Accuracy per corruption type, for the full pipeline and for Jev alone (the ablation).
2. Coverage vs risk: auto-apply every non-escalation decision with confidence >= t, and measure how
   often an auto-applied decision is wrong.
3. A threshold with a statistical guarantee, picked on the calibration split (Learn then Test,
   Angelopoulos et al. 2021, with a Bonferroni correction). Every t on a fixed coarse grid is
   tested with a Clopper-Pearson upper bound at level delta / len(grid); the lowest t whose bound
   is <= alpha wins. With probability >= 1 - delta, every passing t has true risk <= alpha.
   (Fixed-sequence testing was tried first, but it stops at the top of the grid, where too few
   cases sit to prove anything.)
4. That threshold checked on the held-out test split.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SYSTEMS = ("final", "jev")
SYSTEM_NAMES = {"final": "Pipeline (agent + Jev)", "jev": "Jev alone"}
GRID = [round(1 - i / 100, 2) for i in range(51)]  # 1.00 .. 0.50, for the curve
CAL_GRID = [round(1 - i / 20, 2) for i in range(11)]  # 1.00 .. 0.50, fixed before seeing data
ALPHAS = (0.02, 0.05, 0.10)


def is_correct(decision: dict, expected: dict) -> bool:
    if decision["action"] != expected["action"]:
        return False
    return decision["action"] != "reroute" or decision.get("reroute_target") == expected["reroute_target"]


def binom_cdf(k: int, n: int, p: float) -> float:
    return sum(math.comb(n, i) * p**i * (1 - p) ** (n - i) for i in range(k + 1))


def risk_ucb(k: int, n: int, delta: float) -> float:
    """Clopper-Pearson upper bound: largest p with P(X <= k | n, p) >= delta."""
    if n == 0 or k >= n:
        return 1.0
    lo, hi = k / n, 1.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if binom_cdf(k, n, mid) >= delta:
            lo = mid
        else:
            hi = mid
    return hi


def auto_applied(rows: list[dict], system: str, t: float) -> list[dict]:
    return [r for r in rows if r[system]["action"] != "escalate" and r[system]["confidence"] >= t]


def errors(rows: list[dict], system: str) -> int:
    return sum(not is_correct(r[system], r["expected"]) for r in rows)


def curve(rows: list[dict], system: str) -> list[dict]:
    out = []
    for t in GRID:
        auto = auto_applied(rows, system, t)
        k = errors(auto, system)
        out.append({"threshold": t, "coverage": len(auto) / len(rows) if rows else 0.0,
                    "n_auto": len(auto), "errors": k, "risk": k / len(auto) if auto else 0.0})
    return out


def calibrate(rows: list[dict], system: str, alpha: float, delta: float) -> float | None:
    """Lowest CAL_GRID threshold whose Bonferroni-corrected risk bound is <= alpha.
    None means nothing can be auto-applied with this guarantee."""
    level = delta / len(CAL_GRID)
    passing = [t for t in CAL_GRID
               if (auto := auto_applied(rows, system, t)) and risk_ucb(errors(auto, system), len(auto), level) <= alpha]
    return min(passing, default=None)


def load(results_path: Path, cases_path: Path) -> list[dict]:
    cases = {c["case_id"]: c for c in map(json.loads, cases_path.read_text(encoding="utf-8").splitlines())}
    rows = []
    for line in results_path.read_text(encoding="utf-8").splitlines():
        r = json.loads(line)
        c = cases[r["case_id"]]
        rows.append({**r, "expected": c["expected"], "corruption": c["corruption"], "split": c["split"]})
    return rows


def _pct(x: float) -> str:
    return f"{100 * x:.1f}%"


def report(rows: list[dict], delta: float) -> tuple[str, list[dict]]:
    cal = [r for r in rows if r["split"] == "calibration"]
    test = [r for r in rows if r["split"] == "test"]
    providers = sorted({r[s]["provider"] for r in rows for s in SYSTEMS})
    lines = ["# Interop Medic eval", "",
             f"Cases: {len(rows)} ({len(cal)} calibration, {len(test)} test). Providers: {', '.join(providers)}.", ""]
    if any("Mock" in p for p in providers):
        lines += ["> **Mock providers.** The mocks were written with the labels in view, so these numbers only show",
                  "> the harness works. Real accuracy comes from re-running with Jev and the AI Hub agent.", ""]

    lines += ["## Accuracy on the test split", "",
              "| Corruption | n | " + " | ".join(SYSTEM_NAMES[s] for s in SYSTEMS) + " |",
              "|---|---|" + "---|" * len(SYSTEMS)]
    by_type = defaultdict(list)
    for r in test:
        by_type[r["corruption"]].append(r)
    for name, rs in sorted(by_type.items()):
        lines.append(f"| {name} | {len(rs)} | " + " | ".join(_pct(1 - errors(rs, s) / len(rs)) for s in SYSTEMS) + " |")
    lines.append(f"| **all** | {len(test)} | " + " | ".join(f"**{_pct(1 - errors(test, s) / len(test))}**" for s in SYSTEMS) + " |")

    tiers = Counter(r["final"]["decided_by"] for r in test)
    lat = [r["final"]["latency_ms"] for r in test]
    cost = sum(r["final"]["cost_usd"] for r in test)
    lines += ["", "## Pipeline cost and speed (test split)", "",
              f"- Decided by: " + ", ".join(f"{k} {v} ({_pct(v / len(test))})" for k, v in tiers.most_common()),
              f"- Latency: median {statistics.median(lat):.0f} ms, max {max(lat)} ms",
              f"- Estimated cost: ${cost:.6f} total, ${cost / len(test):.8f} per decision (placeholder prices)", ""]

    lines += ["## Auto-apply threshold", "",
              f"Chosen on the calibration split so that, with {_pct(1 - delta)} confidence, the auto-applied error rate",
              "is at most alpha; then checked on the test split. Escalations are never auto-applied.", "",
              "| System | alpha | threshold | test coverage | test errors / auto-applied |", "|---|---|---|---|---|"]
    for s in SYSTEMS:
        for alpha in ALPHAS:
            t = calibrate(cal, s, alpha, delta)
            if t is None:
                lines.append(f"| {SYSTEM_NAMES[s]} | {alpha} | none | 0% | - |")
                continue
            auto = auto_applied(test, s, t)
            lines.append(f"| {SYSTEM_NAMES[s]} | {alpha} | {t:.2f} | {_pct(len(auto) / len(test))} | "
                         f"{errors(auto, s)} / {len(auto)} |")

    curve_rows = [{"system": s, "split": split, **pt}
                  for s in SYSTEMS for split, rs in (("calibration", cal), ("test", test)) for pt in curve(rs, s)]
    return "\n".join(lines) + "\n", curve_rows


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results", type=Path, default=ROOT / "data/results/results.jsonl")
    ap.add_argument("--cases", type=Path, default=ROOT / "dataset/cases.jsonl")
    ap.add_argument("--delta", type=float, default=0.1, help="allowed chance the guarantee fails")
    ap.add_argument("--out", type=Path, default=ROOT / "data/results")
    args = ap.parse_args(argv)

    text, curve_rows = report(load(args.results, args.cases), args.delta)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "report.md").write_text(text, encoding="utf-8")
    with (args.out / "curve.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(curve_rows[0]))
        w.writeheader()
        w.writerows(curve_rows)
    print(text)
    print(f"wrote {args.out / 'report.md'} and {args.out / 'curve.csv'}")


if __name__ == "__main__":
    main()
