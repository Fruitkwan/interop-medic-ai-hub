"""A tiny stand-in System One server (POST /v1/systemone) for testing the SystemOne provider's
plumbing without Jev credentials or Laya weights. It checks the request shape and answers with
crude keyword rules - its accuracy means nothing.

    python eval/fake_systemone.py --port 8765 [--key secret]
    MEDIC_FAST_PROVIDER=Medic.Provider.SystemOne SYSTEMONE_BASE_URL=http://host.docker.internal:8765 docker compose up -d
"""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REQUIRED = {"action": "choice", "severity": "score", "identity_risk": "noul"}


def answer(state: str) -> dict:
    s = state.lower()
    if "timed out" in s or "refused" in s or "http 5" in s:
        action, p = "resend", 0.9
    elif "duplicate" in s:
        action, p = "quarantine", 0.92
    elif "invalid ts" in s or "table 0004" in s:
        action, p = "fix_and_resend", 0.8
    else:
        action, p = "escalate", 0.4
    return {
        "model": "fake-systemone",
        "answers": {
            "action": {"type": "choice", "choice": action, "probabilities": {action: p}, "answer_confidence": p},
            "severity": {"type": "score", "score": 1.0},
            "identity_risk": {"type": "noul", "noul": 0.8 if "mpi mismatch" in s else 0.05},
        },
        "usage": {"input_tokens": len(state) // 4, "output_tokens": 0},
    }


def make_handler(key: str | None):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, status: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):  # noqa: N802
            if self.path.rstrip("/") != "/v1/systemone":
                return self._send(404, {"error": "not found"})
            if key and self.headers.get("Authorization") != f"Bearer {key}":
                return self._send(401, {"error": "bad key"})
            try:
                req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            except json.JSONDecodeError:
                return self._send(400, {"error": "invalid JSON"})
            qs = req.get("questions", {})
            bad = [q for q, t in REQUIRED.items() if qs.get(q, {}).get("type") != t]
            if not isinstance(req.get("state"), str) or bad:
                return self._send(422, {"error": f"bad request shape: {bad or 'state'}"})
            self._send(200, answer(req["state"]))

    return Handler


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--key", help="require Authorization: Bearer <key>")
    args = ap.parse_args()
    print(f"fake System One server on http://{args.host}:{args.port}/v1/systemone", flush=True)
    ThreadingHTTPServer((args.host, args.port), make_handler(args.key)).serve_forever()


if __name__ == "__main__":
    main()
