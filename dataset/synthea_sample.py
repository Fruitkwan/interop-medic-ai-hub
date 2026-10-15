"""Cut a small, committable sample out of a Synthea CSV export for dataset/generate.py --synthea.

Keeps only what the generator needs: living patients' id, birth date, name and sex (no SSN,
passport, address or other identifiers, even though Synthea's are synthetic), and their numeric
results for the lab codes the generator knows reference ranges for.

    python dataset/synthea_sample.py --src data/csv --out dataset/synthea --patients 300
"""

from __future__ import annotations

import argparse
import csv
import random
import re
from collections import defaultdict
from pathlib import Path

# LOINC codes as Synthea emits them, with reference and critical ranges used by generate.py.
LAB_CODES = {"6298-4", "2947-0", "2339-0", "718-7", "6299-2", "49765-1", "2069-3"}
MAX_PER_CODE = 3  # most recent results kept per patient and code


def clean_name(name: str) -> str:
    """Synthea appends digits to names (e.g. 'Jose181'); strip them."""
    return re.sub(r"\d+", "", name).strip()


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", type=Path, default=Path("data/csv"))
    ap.add_argument("--out", type=Path, default=Path(__file__).with_name("synthea"))
    ap.add_argument("--patients", type=int, default=300)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args(argv)

    with (args.src / "patients.csv").open(encoding="utf-8", newline="") as f:
        living = sorted((r for r in csv.DictReader(f) if not r["DEATHDATE"]), key=lambda r: r["Id"])
    chosen = random.Random(args.seed).sample(living, min(args.patients, len(living)))
    ids = {r["Id"] for r in chosen}

    labs = defaultdict(list)
    with (args.src / "observations.csv").open(encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            if r["PATIENT"] in ids and r["CODE"] in LAB_CODES and r["TYPE"] == "numeric":
                labs[(r["PATIENT"], r["CODE"])].append(r)

    args.out.mkdir(parents=True, exist_ok=True)
    with (args.out / "patients.csv").open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "birthdate", "first", "last", "gender"])
        for r in sorted(chosen, key=lambda r: r["Id"]):
            w.writerow([r["Id"], r["BIRTHDATE"], clean_name(r["FIRST"]), clean_name(r["LAST"]), r["GENDER"]])
    n_labs = 0
    with (args.out / "labs.csv").open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["patient", "date", "code", "description", "value", "units"])
        for (pid, code), rows in sorted(labs.items()):
            for r in sorted(rows, key=lambda r: r["DATE"])[-MAX_PER_CODE:]:
                w.writerow([pid, r["DATE"], code, r["DESCRIPTION"], r["VALUE"], r["UNITS"]])
                n_labs += 1
    print(f"wrote {len(chosen)} patients and {n_labs} lab results to {args.out}")


if __name__ == "__main__":
    main()
