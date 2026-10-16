// Four built-in cases (copied from web/data/bundle.json) so the page still has something to triage
// with the browser mock models when the replay bundle is missing or empty.
export const SAMPLE_SCENARIOS = [
 {
  "id": "endpoint_timeout",
  "label": "Endpoint timeout",
  "case": {
   "case_id": "endpoint_timeout-7-0000",
   "corruption": "endpoint_timeout",
   "difficulty": "easy",
   "split": "calibration",
   "synthetic": true,
   "patients": "synthea",
   "format": "hl7v2",
   "message_type": "ORU^R01",
   "raw_message": "MSH|^~\\&|LIS|MEDIC_HOSP|EPR|MEDIC_HOSP|20261004205600||ORU^R01^ORU_R01|MSG132674|P|2.5\rPID|1||47651620^^^MEDIC^MR||Macejkovic^Enedina||19151024|F\rOBR|1||ACC239558|718-7^Hemoglobin^LN|||20261004205600\rOBX|1|NM|718-7^Hemoglobin^LN||16.9|g/dL|12.0-17.5|N|||F\r",
   "clean_message": "MSH|^~\\&|LIS|MEDIC_HOSP|EPR|MEDIC_HOSP|20261004205600||ORU^R01^ORU_R01|MSG132674|P|2.5\rPID|1||47651620^^^MEDIC^MR||Macejkovic^Enedina||19151024|F\rOBR|1||ACC239558|718-7^Hemoglobin^LN|||20261004205600\rOBX|1|NM|718-7^Hemoglobin^LN||16.9|g/dL|12.0-17.5|N|||F\r",
   "error_text": "ERROR #5023: Remote TCP connection timed out after 30 seconds (Medic.To.EPR)",
   "context": {
    "routing_table": {
     "EPR": "Medic.To.EPR",
     "LAB": "Medic.To.LIS",
     "PACS": "Medic.To.PACS"
    },
    "endpoint": {
     "name": "Medic.To.EPR",
     "up": true,
     "down_minutes": 12,
     "last_error": "ERROR #5023: Remote TCP connection timed out after 30 seconds (Medic.To.EPR)"
    }
   }
  }
 },
 {
  "id": "outage_critical_result",
  "label": "Critical result",
  "case": {
   "case_id": "outage_critical_result-7-0000",
   "corruption": "outage_critical_result",
   "difficulty": "hard",
   "split": "calibration",
   "synthetic": true,
   "patients": "synthea",
   "format": "hl7v2",
   "message_type": "ORU^R01",
   "raw_message": "MSH|^~\\&|LIS|MEDIC_HOSP|EPR|MEDIC_HOSP|20261006185900||ORU^R01^ORU_R01|MSG133809|P|2.5\rPID|1||79806972^^^MEDIC^MR||Cruickshank^Vanda||19970730|F\rOBR|1||ACC596257|718-7^Hemoglobin^LN|||20261006185900\rOBX|1|NM|718-7^Hemoglobin^LN||23.6|g/dL|12.0-17.5|HH|||F\r",
   "clean_message": "MSH|^~\\&|LIS|MEDIC_HOSP|EPR|MEDIC_HOSP|20261006185900||ORU^R01^ORU_R01|MSG133809|P|2.5\rPID|1||79806972^^^MEDIC^MR||Cruickshank^Vanda||19970730|F\rOBR|1||ACC596257|718-7^Hemoglobin^LN|||20261006185900\rOBX|1|NM|718-7^Hemoglobin^LN||23.6|g/dL|12.0-17.5|HH|||F\r",
   "error_text": "ERROR #5023: Remote TCP connection timed out after 30 seconds (Medic.To.EPR)",
   "context": {
    "routing_table": {
     "EPR": "Medic.To.EPR",
     "LAB": "Medic.To.LIS",
     "PACS": "Medic.To.PACS"
    },
    "endpoint": {
     "name": "Medic.To.EPR",
     "up": false,
     "down_minutes": 480,
     "last_error": "ERROR #5023: Remote TCP connection timed out after 30 seconds (Medic.To.EPR)"
    }
   }
  }
 },
 {
  "id": "unknown_receiver",
  "label": "Misspelt receiver",
  "case": {
   "case_id": "unknown_receiver-7-0000",
   "corruption": "unknown_receiver",
   "difficulty": "easy",
   "split": "test",
   "synthetic": true,
   "patients": "synthea",
   "format": "hl7v2",
   "message_type": "ADT^A01",
   "raw_message": "MSH|^~\\&|PAS|MEDIC_HOSP|epr|MEDIC_HOSP|20261025185100||ADT^A01^ADT_A01|MSG441582|P|2.5\rEVN|A01|20261025185100\rPID|1||57463926^^^MEDIC^MR||Grimes^Orval||19740723|M\rPV1|1|I|WARD1^101^A\r",
   "clean_message": "MSH|^~\\&|PAS|MEDIC_HOSP|EPR|MEDIC_HOSP|20261025185100||ADT^A01^ADT_A01|MSG441582|P|2.5\rEVN|A01|20261025185100\rPID|1||57463926^^^MEDIC^MR||Grimes^Orval||19740723|M\rPV1|1|I|WARD1^101^A\r",
   "error_text": "ERROR <Ens>ErrNoRuleMatch: No routing rule matched MSH:5 'epr'",
   "context": {
    "routing_table": {
     "EPR": "Medic.To.EPR",
     "LAB": "Medic.To.LIS",
     "PACS": "Medic.To.PACS"
    },
    "endpoint": {
     "name": "Medic.To.EPR",
     "up": true,
     "down_minutes": 0,
     "last_error": ""
    }
   }
  }
 },
 {
  "id": "patient_mismatch",
  "label": "Wrong patient",
  "case": {
   "case_id": "patient_mismatch-7-0000",
   "corruption": "patient_mismatch",
   "difficulty": "hard",
   "split": "calibration",
   "synthetic": true,
   "patients": "synthea",
   "format": "hl7v2",
   "message_type": "ORU^R01",
   "raw_message": "MSH|^~\\&|LIS|MEDIC_HOSP|EPR|MEDIC_HOSP|20261002190600||ORU^R01^ORU_R01|MSG799402|P|2.5\rPID|1||93359838^^^MEDIC^MR||Prosacco^Reggie||20031012|M\rOBR|1||ACC755651|718-7^Hemoglobin^LN|||20261002190600\rOBX|1|NM|718-7^Hemoglobin^LN||16.7|g/dL|12.0-17.5|N|||F\r",
   "clean_message": null,
   "error_text": "ERROR: MPI mismatch - MRN 93359838 registered to Abbott^Jim, message has Prosacco^Reggie",
   "context": {
    "routing_table": {
     "EPR": "Medic.To.EPR",
     "LAB": "Medic.To.LIS",
     "PACS": "Medic.To.PACS"
    },
    "endpoint": {
     "name": "Medic.To.EPR",
     "up": true,
     "down_minutes": 0,
     "last_error": ""
    },
    "mpi": {
     "mrn": "93359838",
     "family": "Abbott",
     "given": "Jim"
    }
   }
  }
 }
];
