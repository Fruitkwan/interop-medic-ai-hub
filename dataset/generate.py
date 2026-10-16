"""Synthetic broken HL7 v2 / FHIR message generator for Interop Medic.

Every case is a failed interoperability message plus the context an operator
would look at (error text, endpoint health, routing table, MPI lookup) and the
known-correct triage decision. All patients are synthetic - never put real
messages in this dataset. Patients and lab results come from a built-in list, or
from a Synthea sample (--synthea) for realistic names, ages and lab values.

Usage:
    uv run python dataset/generate.py --synthea dataset/synthea --cases-dir data/cases
    uv run python dataset/generate.py --n-per-type 25 --seed 7   # built-in patients, no files needed
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import random
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable

ACTIONS = ("resend", "fix_and_resend", "reroute", "quarantine", "escalate")

ROUTING = {
    "EPR": "Medic.To.EPR",
    "LAB": "Medic.To.LIS",
    "PACS": "Medic.To.PACS",
}
RECEIVER_TYPOS = {
    "EPR": ["EPR1", "EPRR", "EP R", "epr"],
    "LAB": ["LABS", "LAB_TEST", "LBA"],
    "PACS": ["PACS2", "PAC"],
}

GIVEN = ["Alex", "Sam", "Jordan", "Riley", "Casey", "Morgan", "Taylor", "Jamie", "Avery", "Quinn"]
FAMILY = ["Testwood", "Synthson", "Mockley", "Fakhoury", "Demarco", "Placeholt", "Sampleton", "Dummer"]

# LOINC code -> (name, unit, reference low, reference high, critical low, critical high).
# Codes match what Synthea emits. Codes without critical limits are never used for critical results.
LABS = {
    "6298-4": ("Potassium", "mmol/L", 3.5, 5.1, 2.5, 6.5),
    "2947-0": ("Sodium", "mmol/L", 136, 145, 120, 160),
    "2339-0": ("Glucose", "mg/dL", 70, 99, 40, 450),
    "718-7": ("Hemoglobin", "g/dL", 12.0, 17.5, 6.5, 20.0),
    "49765-1": ("Calcium", "mg/dL", 8.5, 10.2, 6.5, 13.0),
    "6299-2": ("Urea Nitrogen", "mg/dL", 7, 20, None, None),
    "2069-3": ("Chloride", "mmol/L", 98, 107, None, None),
}
CRITICAL_CODES = sorted(c for c, v in LABS.items() if v[4] is not None)

PATIENT_CLASS_MAP = {"INPT": "I", "OUTPT": "O", "EMER": "E", "INPATIENT": "I"}


@dataclass
class Patient:
    mrn: str
    given: str
    family: str
    dob: datetime
    sex: str
    source_id: str = ""


@dataclass
class Lab:
    code: str
    name: str
    unit: str
    ref: str
    value: float
    flag: str


def make_lab(rng: random.Random, code: str, value: float | None = None, critical: bool = False) -> Lab:
    """A lab result for code. With critical=True the value is pushed past the critical limit
    (Synthea results are almost all in range, so critical results are always derived)."""
    name, unit, lo, hi, clo, chi = LABS[code]
    if critical:
        value = round(clo * rng.uniform(0.85, 0.97), 1) if rng.random() < 0.5 else round(chi * rng.uniform(1.03, 1.2), 1)
    elif value is None:
        value = round(rng.uniform(lo, hi), 1)
    if clo is not None and value < clo:
        flag = "LL"
    elif chi is not None and value > chi:
        flag = "HH"
    else:
        flag = "L" if value < lo else "H" if value > hi else "N"
    return Lab(code, name, unit, f"{lo}-{hi}", value, flag)


class BuiltinSource:
    """Made-up patients and in-range lab values. Needs no files."""
    name = "builtin"

    def patient(self, rng: random.Random) -> Patient:
        dob = datetime(1930, 1, 1) + timedelta(days=rng.randrange(0, 33000))
        return Patient(mrn=f"{rng.randrange(10_000_000, 99_999_999)}", given=rng.choice(GIVEN),
                       family=rng.choice(FAMILY), dob=dob, sex=rng.choice("MF"))

    def lab(self, rng: random.Random, p: Patient, critical: bool = False) -> Lab:
        return make_lab(rng, rng.choice(CRITICAL_CODES if critical else sorted(LABS)), critical=critical)


class SyntheaSource:
    """Synthea patients (name, birth date, sex) and their real lab results, from the sample
    written by dataset/synthea_sample.py."""
    name = "synthea"

    def __init__(self, folder: Path):
        with (folder / "patients.csv").open(encoding="utf-8", newline="") as f:
            self.patients = [Patient(mrn=self.mrn(r["id"]), given=r["first"], family=r["last"],
                                     dob=datetime.strptime(r["birthdate"], "%Y-%m-%d"), sex=r["gender"],
                                     source_id=r["id"])
                             for r in csv.DictReader(f)]
        self.labs: dict[str, list[tuple[str, float]]] = {}
        with (folder / "labs.csv").open(encoding="utf-8", newline="") as f:
            for r in csv.DictReader(f):
                if r["code"] in LABS:
                    self.labs.setdefault(r["patient"], []).append((r["code"], float(r["value"])))
        if not self.patients:
            raise ValueError(f"no patients in {folder}")

    @staticmethod
    def mrn(synthea_id: str) -> str:
        return str(int(hashlib.sha256(synthea_id.encode()).hexdigest()[:12], 16) % 90_000_000 + 10_000_000)

    def patient(self, rng: random.Random) -> Patient:
        return rng.choice(self.patients)

    def lab(self, rng: random.Random, p: Patient, critical: bool = False) -> Lab:
        own = self.labs.get(p.source_id, [])
        if critical:
            own = [o for o in own if o[0] in CRITICAL_CODES]
            code = rng.choice(own)[0] if own else rng.choice(CRITICAL_CODES)
            return make_lab(rng, code, critical=True)
        if own:
            code, value = rng.choice(own)
            return make_lab(rng, code, value)
        return make_lab(rng, rng.choice(sorted(LABS)))


def _ts(rng: random.Random) -> str:
    t = datetime(2026, 10, 1) + timedelta(minutes=rng.randrange(0, 60 * 24 * 30))
    return t.strftime("%Y%m%d%H%M%S")


def _control_id(rng: random.Random) -> str:
    return f"MSG{rng.randrange(100000, 999999)}"


# --------------------------------------------------------------------------- HL7 builders

def _hl7(segments: list[str]) -> str:
    return "\r".join(segments) + "\r"


def _msh(sender: str, receiver: str, ts: str, msg_type: str, control_id: str) -> str:
    return f"MSH|^~\\&|{sender}|MEDIC_HOSP|{receiver}|MEDIC_HOSP|{ts}||{msg_type}|{control_id}|P|2.5"


def _pid(p: Patient, *, mrn: str | None = None, dob: str | None = None) -> str:
    mrn = p.mrn if mrn is None else mrn
    dob = p.dob.strftime("%Y%m%d") if dob is None else dob
    ident = f"{mrn}^^^MEDIC^MR" if mrn else ""
    return f"PID|1||{ident}||{p.family}^{p.given}||{dob}|{p.sex}"


def adt_segments(p: Patient, receiver: str, ts: str, control_id: str, *,
                 patient_class: str = "I", mrn: str | None = None, dob: str | None = None) -> list[str]:
    return [
        _msh("PAS", receiver, ts, "ADT^A01^ADT_A01", control_id),
        f"EVN|A01|{ts}",
        _pid(p, mrn=mrn, dob=dob),
        f"PV1|1|{patient_class}|WARD1^101^A",
    ]


def oru_segments(rng: random.Random, src, p: Patient, receiver: str, ts: str, control_id: str, *,
                 critical: bool = False, mrn: str | None = None) -> list[str]:
    lab = src.lab(rng, p, critical)
    return [
        _msh("LIS", receiver, ts, "ORU^R01^ORU_R01", control_id),
        _pid(p, mrn=mrn),
        f"OBR|1||ACC{rng.randrange(100000, 999999)}|{lab.code}^{lab.name}^LN|||{ts}",
        f"OBX|1|NM|{lab.code}^{lab.name}^LN||{lab.value}|{lab.unit}|{lab.ref}|{lab.flag}|||F",
    ]


# --------------------------------------------------------------------------- FHIR builders

def fhir_patient(p: Patient, *, birth_date: str | None = None, resource_type: str = "Patient") -> dict:
    return {
        "resourceType": resource_type,
        "id": f"pat-{p.mrn}",
        "identifier": [{"system": "urn:medic:mrn", "value": p.mrn}],
        "name": [{"family": p.family, "given": [p.given]}],
        "gender": "male" if p.sex == "M" else "female",
        "birthDate": birth_date or p.dob.strftime("%Y-%m-%d"),
    }


def fhir_observation(rng: random.Random, src, p: Patient, *, with_subject: bool = True) -> dict:
    lab = src.lab(rng, p)
    obs = {
        "resourceType": "Observation",
        "id": f"obs-{rng.randrange(100000, 999999)}",
        "status": "final",
        "code": {"coding": [{"system": "http://loinc.org", "code": lab.code, "display": lab.name}]},
        "valueQuantity": {"value": lab.value, "unit": lab.unit},
    }
    if with_subject:
        obs["subject"] = {"reference": f"Patient/pat-{p.mrn}"}
    return obs


def _json(resource: dict) -> str:
    return json.dumps(resource, indent=2)


# --------------------------------------------------------------------------- context helpers

def _endpoint(name: str, *, up: bool = True, down_minutes: int = 0, last_error: str = "") -> dict:
    return {"name": name, "up": up, "down_minutes": down_minutes, "last_error": last_error}


def _context(target: str, **extra) -> dict:
    ctx = {"routing_table": dict(ROUTING), "endpoint": _endpoint(target)}
    ctx.update(extra)
    return ctx


def _pick(rng: random.Random, templates: list[str], **kw) -> str:
    return rng.choice(templates).format(**kw)


# --------------------------------------------------------------------------- corruption types
# Each returns a partial case dict: raw/clean message, error text, context, expected decision.

def c_bad_date_format(rng, src):
    p, ts, cid = src.patient(rng), _ts(rng), _control_id(rng)
    bad = p.dob.strftime("%Y/%m/%d") if rng.random() < 0.5 else p.dob.strftime("%Y-%m-%d")
    clean = _hl7(adt_segments(p, "EPR", ts, cid))
    raw = _hl7(adt_segments(p, "EPR", ts, cid, dob=bad))
    err = _pick(rng, [
        "ERROR <EnsEDI>ErrDataType: Invalid TS value '{v}' in PID:7",
        "ERROR #5006: Validation failed for segment PID field 7 (Date/Time of Birth): '{v}'",
    ], v=bad)
    return dict(format="hl7v2", message_type="ADT^A01", raw_message=raw, clean_message=clean,
                error_text=err, context=_context("Medic.To.EPR"),
                expected=dict(action="fix_and_resend", severity=0.2,
                              fix_hint=f"Reformat PID-7 '{bad}' as YYYYMMDD ({p.dob:%Y%m%d})"))


def c_ambiguous_date(rng, src):
    # dd/mm vs mm/dd cannot be resolved safely - a wrong birth date is an identity risk.
    p = src.patient(rng)
    while p.dob.day > 12 or p.dob.day == p.dob.month:
        p = src.patient(rng)
    ts, cid = _ts(rng), _control_id(rng)
    bad = p.dob.strftime("%d/%m/%Y")
    raw = _hl7(adt_segments(p, "EPR", ts, cid, dob=bad))
    err = f"ERROR <EnsEDI>ErrDataType: Invalid TS value '{bad}' in PID:7"
    return dict(format="hl7v2", message_type="ADT^A01", raw_message=raw, clean_message=None,
                error_text=err, context=_context("Medic.To.EPR"), difficulty="hard",
                expected=dict(action="escalate", severity=0.5,
                              fix_hint="Day/month order is ambiguous; confirm DOB with the source system"))


def c_invalid_patient_class(rng, src):
    p, ts, cid = src.patient(rng), _ts(rng), _control_id(rng)
    bad, good = rng.choice(list(PATIENT_CLASS_MAP.items()))
    clean = _hl7(adt_segments(p, "EPR", ts, cid, patient_class=good))
    raw = _hl7(adt_segments(p, "EPR", ts, cid, patient_class=bad))
    err = _pick(rng, [
        "ERROR <EnsEDI>ErrBadCode: Value '{v}' not in table 0004 for PV1:2",
        "ERROR: PV1-2 Patient Class '{v}' is not a valid HL7 table 0004 code",
    ], v=bad)
    return dict(format="hl7v2", message_type="ADT^A01", raw_message=raw, clean_message=clean,
                error_text=err, context=_context("Medic.To.EPR"),
                expected=dict(action="fix_and_resend", severity=0.25,
                              fix_hint=f"Map PV1-2 '{bad}' to '{good}' via a DTL lookup"))


def c_segment_order(rng, src):
    p, ts, cid = src.patient(rng), _ts(rng), _control_id(rng)
    segs = adt_segments(p, "EPR", ts, cid)
    clean = _hl7(segs)
    raw = _hl7([segs[0], segs[1], segs[3], segs[2]])
    err = "ERROR <EnsEDI>ErrUnexpectedSegment: Segment 'PV1' found where 'PID' expected (2.5:ADT_A01)"
    return dict(format="hl7v2", message_type="ADT^A01", raw_message=raw, clean_message=clean,
                error_text=err, context=_context("Medic.To.EPR"),
                expected=dict(action="fix_and_resend", severity=0.2, fix_hint="Move PID before PV1"))


def c_endpoint_timeout(rng, src):
    p, ts, cid = src.patient(rng), _ts(rng), _control_id(rng)
    raw = _hl7(oru_segments(rng, src, p, "EPR", ts, cid))
    mins = rng.randrange(1, 20)
    err = _pick(rng, [
        "ERROR #5023: Remote TCP connection timed out after 30 seconds (Medic.To.EPR)",
        "ERROR <Ens>ErrOutConnectFailed: Connection to 10.0.4.12:6661 refused",
    ])
    ctx = _context("Medic.To.EPR", endpoint=_endpoint("Medic.To.EPR", up=rng.random() < 0.6,
                                                         down_minutes=mins, last_error=err))
    return dict(format="hl7v2", message_type="ORU^R01", raw_message=raw, clean_message=raw,
                error_text=err, context=ctx,
                expected=dict(action="resend", severity=0.3, fix_hint="Transient outage; resend once endpoint is up"))


def c_outage_critical_result(rng, src):
    # Same error as a plain timeout, but a critical result stuck behind a long outage needs a human.
    p, ts, cid = src.patient(rng), _ts(rng), _control_id(rng)
    raw = _hl7(oru_segments(rng, src, p, "EPR", ts, cid, critical=True))
    err = "ERROR #5023: Remote TCP connection timed out after 30 seconds (Medic.To.EPR)"
    ctx = _context("Medic.To.EPR", endpoint=_endpoint("Medic.To.EPR", up=False,
                                                         down_minutes=rng.randrange(180, 600), last_error=err))
    return dict(format="hl7v2", message_type="ORU^R01", raw_message=raw, clean_message=raw,
                error_text=err, context=ctx, difficulty="hard",
                expected=dict(action="escalate", severity=0.95,
                              fix_hint="Critical (HH/LL) result undelivered during prolonged outage; phone the ward"))


def c_unknown_receiver(rng, src):
    p, ts, cid = src.patient(rng), _ts(rng), _control_id(rng)
    good = rng.choice(list(ROUTING))
    bad = rng.choice(RECEIVER_TYPOS[good])
    clean = _hl7(adt_segments(p, good, ts, cid))
    raw = _hl7(adt_segments(p, bad, ts, cid))
    err = _pick(rng, [
        "ERROR <Ens>ErrNoRuleMatch: No routing rule matched MSH:5 '{v}'",
        "ERROR: Router Medic.Router found no target for ReceivingApplication '{v}'",
    ], v=bad)
    return dict(format="hl7v2", message_type="ADT^A01", raw_message=raw, clean_message=clean,
                error_text=err, context=_context(ROUTING[good]),
                expected=dict(action="reroute", severity=0.4, reroute_target=ROUTING[good],
                              fix_hint=f"MSH-5 '{bad}' is a variant of '{good}'; route to {ROUTING[good]}"))


def c_unroutable(rng, src):
    # Same error as a typo'd receiver, but nothing in the routing table is close - guessing a route is unsafe.
    p, ts, cid = src.patient(rng), _ts(rng), _control_id(rng)
    bad = rng.choice(["BILLING", "ORDERCOMMS", "PHARMACY", "DIETARY", "CARDIO"])
    raw = _hl7(adt_segments(p, bad, ts, cid))
    err = _pick(rng, [
        "ERROR <Ens>ErrNoRuleMatch: No routing rule matched MSH:5 '{v}'",
        "ERROR: Router Medic.Router found no target for ReceivingApplication '{v}'",
    ], v=bad)
    return dict(format="hl7v2", message_type="ADT^A01", raw_message=raw, clean_message=None,
                error_text=err, context=_context("Medic.To.EPR"), difficulty="hard",
                expected=dict(action="escalate", severity=0.4,
                              fix_hint=f"No route resembles '{bad}'; a new routing rule needs an owner"))


def c_duplicate(rng, src):
    p, ts, cid = src.patient(rng), _ts(rng), _control_id(rng)
    raw = _hl7(adt_segments(p, "EPR", ts, cid))
    err = f"ERROR: Duplicate message control ID '{cid}' already processed (MSH:10)"
    ctx = _context("Medic.To.EPR", seen_control_ids=[cid])
    return dict(format="hl7v2", message_type="ADT^A01", raw_message=raw, clean_message=None,
                error_text=err, context=ctx,
                expected=dict(action="quarantine", severity=0.1, fix_hint="Duplicate; do not resend"))


def c_missing_mrn(rng, src):
    p, ts, cid = src.patient(rng), _ts(rng), _control_id(rng)
    raw = _hl7(adt_segments(p, "EPR", ts, cid, mrn=""))
    err = _pick(rng, [
        "ERROR <EnsEDI>ErrRequiredField: Required field PID:3 (Patient Identifier List) missing",
        "ERROR: PID-3 is empty; cannot match patient in EPR",
    ])
    return dict(format="hl7v2", message_type="ADT^A01", raw_message=raw, clean_message=None,
                error_text=err, context=_context("Medic.To.EPR"),
                expected=dict(action="escalate", severity=0.7, fix_hint="No patient identifier; source must correct"))


def c_patient_mismatch(rng, src):
    p, other, ts, cid = src.patient(rng), src.patient(rng), _ts(rng), _control_id(rng)
    while other.family == p.family:
        other = src.patient(rng)
    raw = _hl7(oru_segments(rng, src, p, "EPR", ts, cid))
    err = f"ERROR: MPI mismatch - MRN {p.mrn} registered to {other.family}^{other.given}, message has {p.family}^{p.given}"
    ctx = _context("Medic.To.EPR", mpi={"mrn": p.mrn, "family": other.family, "given": other.given})
    return dict(format="hl7v2", message_type="ORU^R01", raw_message=raw, clean_message=None,
                error_text=err, context=ctx, difficulty="hard",
                expected=dict(action="escalate", severity=0.9,
                              fix_hint="Possible wrong-patient result; never auto-correct identity"))


def c_truncated(rng, src):
    p, ts, cid = src.patient(rng), _ts(rng), _control_id(rng)
    full = _hl7(adt_segments(p, "EPR", ts, cid))
    raw = full[: rng.randrange(40, len(full.split("\r")[0]) + 10)]
    err = _pick(rng, [
        "ERROR <EnsEDI>ErrBadDocument: Unexpected end of message; no PID segment",
        "ERROR #6301: Malformed HL7 message - incomplete MSH/segment terminator",
    ])
    return dict(format="hl7v2", message_type="ADT^A01", raw_message=raw, clean_message=None,
                error_text=err, context=_context("Medic.To.EPR"),
                expected=dict(action="quarantine", severity=0.5, fix_hint="Unrecoverable; request resend from PAS"))


def c_fhir_bad_date(rng, src):
    p = src.patient(rng)
    bad = p.dob.strftime("%Y%m%d")
    raw = _json(fhir_patient(p, birth_date=bad))
    clean = _json(fhir_patient(p))
    err = f"HTTP 400 OperationOutcome: Patient.birthDate '{bad}' is not a valid FHIR date (YYYY-MM-DD)"
    return dict(format="fhir", message_type="Patient", raw_message=raw, clean_message=clean,
                error_text=err, context=_context("Medic.To.FHIR"),
                expected=dict(action="fix_and_resend", severity=0.2,
                              fix_hint=f"Set birthDate to {p.dob:%Y-%m-%d}"))


def c_fhir_resource_type(rng, src):
    p = src.patient(rng)
    bad = rng.choice(["patient", "PATIENT", "Patients"])
    raw = _json(fhir_patient(p, resource_type=bad))
    clean = _json(fhir_patient(p))
    err = f"HTTP 400 OperationOutcome: Unknown resourceType '{bad}'"
    return dict(format="fhir", message_type="Patient", raw_message=raw, clean_message=clean,
                error_text=err, context=_context("Medic.To.FHIR"),
                expected=dict(action="fix_and_resend", severity=0.15, fix_hint="Set resourceType to 'Patient'"))


def c_fhir_missing_subject(rng, src):
    p = src.patient(rng)
    raw = _json(fhir_observation(rng, src, p, with_subject=False))
    err = "HTTP 422 OperationOutcome: Observation.subject is required by profile medic-lab-result"
    return dict(format="fhir", message_type="Observation", raw_message=raw, clean_message=None,
                error_text=err, context=_context("Medic.To.FHIR"),
                expected=dict(action="escalate", severity=0.8,
                              fix_hint="Result has no patient; cannot infer subject safely"))


def c_fhir_server_5xx(rng, src):
    p = src.patient(rng)
    raw = _json(fhir_observation(rng, src, p))
    code = rng.choice([502, 503, 504])
    err = f"HTTP {code} from https://fhir.medic.local/r4/Observation"
    ctx = _context("Medic.To.FHIR", endpoint=_endpoint("Medic.To.FHIR", up=True,
                                                          down_minutes=rng.randrange(0, 5), last_error=err))
    return dict(format="fhir", message_type="Observation", raw_message=raw, clean_message=raw,
                error_text=err, context=ctx,
                expected=dict(action="resend", severity=0.3, fix_hint="Transient server error; resend"))


CORRUPTIONS: dict[str, Callable[[random.Random], dict]] = {
    "bad_date_format": c_bad_date_format,
    "ambiguous_date": c_ambiguous_date,
    "invalid_patient_class": c_invalid_patient_class,
    "segment_order": c_segment_order,
    "endpoint_timeout": c_endpoint_timeout,
    "outage_critical_result": c_outage_critical_result,
    "unknown_receiver": c_unknown_receiver,
    "unroutable": c_unroutable,
    "duplicate": c_duplicate,
    "missing_mrn": c_missing_mrn,
    "patient_mismatch": c_patient_mismatch,
    "truncated": c_truncated,
    "fhir_bad_date": c_fhir_bad_date,
    "fhir_resource_type": c_fhir_resource_type,
    "fhir_missing_subject": c_fhir_missing_subject,
    "fhir_server_5xx": c_fhir_server_5xx,
}

# Multiplier on n_per_type, so rarer actions still have enough cases to calibrate on.
WEIGHTS = {"unknown_receiver": 3}


# --------------------------------------------------------------------------- assembly

def _split(case_id: str, calibration_share: float) -> str:
    h = int(hashlib.sha256(case_id.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    return "calibration" if h < calibration_share else "test"


def generate(n_per_type: int = 25, seed: int = 7, calibration_share: float = 0.6, source=None) -> list[dict]:
    rng = random.Random(seed)
    src = source or BuiltinSource()
    cases = []
    for corruption, build in CORRUPTIONS.items():
        for i in range(n_per_type * WEIGHTS.get(corruption, 1)):
            case = build(rng, src)
            case_id = f"{corruption}-{seed}-{i:04d}"
            expected = {"reroute_target": None, **case.pop("expected")}
            expected["severity"] = round(min(1.0, max(0.0, expected["severity"] + rng.uniform(-0.05, 0.05))), 2)
            if expected["action"] == "fix_and_resend":
                expected["fixed_message"] = case["clean_message"]
            cases.append({
                "case_id": case_id,
                "corruption": corruption,
                "difficulty": case.pop("difficulty", "easy"),
                "split": _split(case_id, calibration_share),
                "synthetic": True,
                "patients": src.name,
                **case,
                "expected": expected,
            })
    return cases


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n-per-type", type=int, default=25)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--calibration-share", type=float, default=0.6)
    ap.add_argument("--out", type=Path, default=Path(__file__).with_name("cases.jsonl"))
    ap.add_argument("--cases-dir", type=Path, help="also write one <case_id>.json per case (demo feed input)")
    ap.add_argument("--synthea", type=Path, help="take patients and lab results from a Synthea sample "
                                                  "(dataset/synthea, made by dataset/synthea_sample.py)")
    args = ap.parse_args(argv)

    source = SyntheaSource(args.synthea) if args.synthea else None
    cases = generate(args.n_per_type, args.seed, args.calibration_share, source)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8", newline="\n") as f:
        for c in cases:
            f.write(json.dumps(c) + "\n")
    if args.cases_dir:
        args.cases_dir.mkdir(parents=True, exist_ok=True)
        for c in cases:
            (args.cases_dir / f"{c['case_id']}.json").write_text(json.dumps(c, indent=2), encoding="utf-8")

    by_action: dict[str, int] = {}
    for c in cases:
        by_action[c["expected"]["action"]] = by_action.get(c["expected"]["action"], 0) + 1
    print(f"wrote {len(cases)} cases to {args.out}  " + "  ".join(f"{k}={v}" for k, v in sorted(by_action.items())))


if __name__ == "__main__":
    main()
