"""End-to-end smoke test: send one trace with the Langfuse Python SDK and read
it back through the public API.

Run from the repo root against the LOCAL stack (needs `pip install langfuse==4.18.0`):

    python ci/smoke_trace.py                 # base URL http://localhost:3300
    python ci/smoke_trace.py --base-url URL --secrets-dir DIR

Keys are read from the init_project_*_key files in the secrets dir (never
printed). Exits non-zero, with the reason, unless:
- the trace's observation shows up in project `magenticx` within the timeout
  (read through the v4 Observations API v2; v4 no longer fills the legacy
  /api/public/traces tables), and
- the app-side mask hook (the same one docs/app-integration.md asks the apps
  to use) replaced the fake API key and e-mail before they left the process.
"""

import argparse
import base64
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from langfuse import Langfuse

PROJECT_ID = "magenticx"

# Same patterns as docs/app-integration.md § Masking.
_PATTERNS = [
    (re.compile(r"\b(?:sk|pk)-lf-[A-Za-z0-9-]{8,}"), "[REDACTED_LANGFUSE_KEY]"),
    (re.compile(r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}"), "[REDACTED_API_KEY]"),
    (re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"), "[REDACTED_AWS_KEY]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"), "[REDACTED_GITHUB_TOKEN]"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"), "[REDACTED_JWT]"),
    (re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{16,}=*"), "Bearer [REDACTED]"),
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "[REDACTED_EMAIL]"),
]


def _mask_str(value: str) -> str:
    for pattern, repl in _PATTERNS:
        value = pattern.sub(repl, value)
    return value


def mask(*, data, **_kwargs):
    """Recursively mask strings in any JSON-like structure."""
    if isinstance(data, str):
        return _mask_str(data)
    if isinstance(data, dict):
        return {k: mask(data=v) for k, v in data.items()}
    if isinstance(data, (list, tuple)):
        return [mask(data=v) for v in data]
    return data


def fetch_observations(base_url: str, auth: str, trace_id: str) -> list[dict]:
    query = urllib.parse.urlencode({"traceId": trace_id, "fields": "core,io"})
    req = urllib.request.Request(
        f"{base_url}/api/public/v2/observations?{query}",
        headers={"Authorization": f"Basic {auth}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.load(resp).get("data") or []
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return []
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://localhost:3300")
    parser.add_argument("--secrets-dir", default="secrets", type=Path)
    parser.add_argument("--timeout", default=90, type=int)
    args = parser.parse_args()

    public_key = (args.secrets_dir / "init_project_public_key").read_text().strip()
    secret_key = (args.secrets_dir / "init_project_secret_key").read_text().strip()
    auth = base64.b64encode(f"{public_key}:{secret_key}".encode()).decode()

    fake_secret = "sk-proj-" + "A1b2C3d4E5f6G7h8I9j0K1l2"
    fake_email = "jane.doe@example.org"

    lf = Langfuse(public_key=public_key, secret_key=secret_key, base_url=args.base_url, mask=mask)
    with lf.start_as_current_observation(as_type="span", name="smoke-trace") as span:
        span.update(
            input={"question": f"my key is {fake_secret}, mail me at {fake_email}"},
            output={"answer": "ok"},
            metadata={"source": "langfuse/ci/smoke_trace.py"},
        )
        trace_id = lf.get_current_trace_id()
    lf.flush()
    lf.shutdown()
    print(f"sent trace {trace_id}")

    deadline = time.monotonic() + args.timeout
    observations: list[dict] = []
    while time.monotonic() < deadline:
        observations = fetch_observations(args.base_url, auth, trace_id)
        if observations:
            break
        time.sleep(3)
    if not observations:
        print(f"FAILED: trace {trace_id} not readable after {args.timeout}s")
        return 1

    errors = []
    projects = {o.get("projectId") for o in observations}
    if projects != {PROJECT_ID}:
        errors.append(f"trace is in project(s) {sorted(map(str, projects))}, expected {PROJECT_ID!r}")
    stored = json.dumps(observations)
    if fake_secret in stored or fake_email in stored:
        errors.append("mask hook did not redact the fake API key / e-mail")
    if "[REDACTED_API_KEY]" not in stored or "[REDACTED_EMAIL]" not in stored:
        errors.append("redaction markers missing from the stored input")

    for err in errors:
        print(f"FAILED: {err}")
    if not errors:
        print(f"OK: trace {trace_id} in project {PROJECT_ID}, input masked: {observations[0].get('input')}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
