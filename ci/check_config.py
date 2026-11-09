"""Static policy checks on the two compose files.

Run from the repo root: python ci/check_config.py
Exits non-zero, listing every problem, when:
- a compose file does not parse, or the two define different services;
- a service differs between local and Dennis in image, limits, secrets,
  security options or environment (except the documented per-site keys);
- an image is not pinned as tag@sha256:digest;
- Dennis publishes a host port, or local publishes anything but the UI on
  127.0.0.1;
- the long-running services' memory limits add up to more than the budget;
- a long-running service has no healthcheck, or a service lacks
  no-new-privileges, cap_drop ALL, a pids limit or the bounded json-file log;
- an environment variable looks like an inline secret (secrets are *_FILE);
- a secret file isn't produced by scripts/gen-secrets.sh;
- anything but langfuse-web joins the shared networks (`langfuse`, `proxy`);
- telemetry, sign-up or JSON logging drift from the policy.
"""

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
LOCAL, DENNIS = "docker-compose.yaml", "docker-compose-denis.yaml"
MEMORY_BUDGET_MIB = 4096
WEB = "langfuse-web"
SHARED_NETWORKS = {"langfuse", "proxy"}
# Environment keys allowed to differ between the two sites.
SITE_KEYS = {"NEXTAUTH_URL", "LANGFUSE_CSP_ENFORCE_HTTPS"}
SENSITIVE = re.compile(r"PASSWORD|SECRET|SALT|ENCRYPTION_KEY|_AUTH$|PRIVATE|TOKEN|PUBLIC_KEY")
PINNED = re.compile(r"^[^@\s]+:[^@\s]+@sha256:[0-9a-f]{64}$|^[^@:\s]+@sha256:[0-9a-f]{64}$")
UNITS = {"k": 1 / 1024, "m": 1, "g": 1024}
SAME_KEYS = ("image", "mem_limit", "cpus", "pids_limit", "security_opt", "cap_drop",
             "cap_add", "user", "entrypoint", "command", "healthcheck", "ulimits",
             "logging", "restart", "depends_on", "shm_size", "tmpfs")


def load(name: str) -> dict:
    with (ROOT / name).open(encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def mib(value: str) -> float:
    m = re.fullmatch(r"(\d+(?:\.\d+)?)([kmg])b?", str(value).lower())
    if not m:
        raise ValueError(f"unparseable mem_limit {value!r}")
    return float(m.group(1)) * UNITS[m.group(2)]


def env_of(svc: dict) -> dict:
    env = svc.get("environment") or {}
    if isinstance(env, list):
        env = dict(item.split("=", 1) for item in env)
    return env


def generated_secret_files() -> set[str]:
    text = (ROOT / "scripts/gen-secrets.sh").read_text(encoding="utf-8")
    return set(re.findall(r"^write ([a-z0-9_.]+) ", text, re.M))


def check_site(name: str, compose: dict, errors: list[str]) -> None:
    services = compose.get("services") or {}
    total = 0.0
    for sname, svc in services.items():
        where = f"{name}: {sname}"
        image = str(svc.get("image", ""))
        if not PINNED.match(image):
            errors.append(f"{where}: image not pinned as tag@sha256: {image!r}")
        one_shot = str(svc.get("restart", "")) == "no"
        if "mem_limit" not in svc:
            errors.append(f"{where}: no mem_limit")
        elif not one_shot:
            total += mib(svc["mem_limit"])
        if not one_shot and "healthcheck" not in svc:
            errors.append(f"{where}: long-running service without a healthcheck")
        if "no-new-privileges:true" not in (svc.get("security_opt") or []):
            errors.append(f"{where}: missing security_opt no-new-privileges:true")
        if (svc.get("cap_drop") or []) != ["ALL"]:
            errors.append(f"{where}: cap_drop must be [ALL]")
        if "pids_limit" not in svc:
            errors.append(f"{where}: no pids_limit")
        log = svc.get("logging") or {}
        if log.get("driver") != "json-file" or "max-size" not in (log.get("options") or {}):
            errors.append(f"{where}: logging must be json-file with max-size")
        for key, value in env_of(svc).items():
            if key.endswith("_FILE"):
                if not str(value).startswith("/run/secrets/"):
                    errors.append(f"{where}: {key} must point under /run/secrets/")
                continue
            if SENSITIVE.search(key):
                errors.append(f"{where}: {key} looks like an inline secret (use {key}_FILE)")
        nets = set(svc.get("networks") or [])
        if sname != WEB and nets & SHARED_NETWORKS:
            errors.append(f"{where}: only {WEB} may join {sorted(SHARED_NETWORKS)}")
        ports = svc.get("ports") or []
        if name == DENNIS and ports:
            errors.append(f"{where}: Dennis publishes no host ports (NPM reaches it over the proxy network)")
        if name == LOCAL:
            for p in ports:
                if sname != WEB or not str(p).startswith("127.0.0.1:"):
                    errors.append(f"{where}: local port {p!r} must be {WEB} on 127.0.0.1 only")
    if total > MEMORY_BUDGET_MIB:
        errors.append(f"{name}: long-running mem_limit total {total:.0f} MiB > budget {MEMORY_BUDGET_MIB} MiB")
    else:
        print(f"{name}: long-running memory limits {total:.0f} MiB (budget {MEMORY_BUDGET_MIB})")

    web_env = env_of(services.get(WEB, {}))
    for key, want in (("TELEMETRY_ENABLED", "false"), ("AUTH_DISABLE_SIGNUP", "true"),
                      ("NEXT_PUBLIC_SIGN_UP_DISABLED", "true"), ("LANGFUSE_LOG_FORMAT", "json")):
        if str(web_env.get(key)) != want:
            errors.append(f"{name}: {WEB} {key} must be {want!r}, is {web_env.get(key)!r}")

    produced = generated_secret_files()
    for sec_name, sec in (compose.get("secrets") or {}).items():
        file_name = Path(str(sec.get("file", ""))).name
        if file_name not in produced:
            errors.append(f"{name}: secret {sec_name} file {file_name!r} is not made by scripts/gen-secrets.sh")
        if name == DENNIS and not str(sec.get("file", "")).startswith("/opt/langfuse/secrets/"):
            errors.append(f"{name}: secret {sec_name} must live in /opt/langfuse/secrets/")

    if name == DENNIS:
        nets = compose.get("networks") or {}
        for shared in SHARED_NETWORKS:
            if not (nets.get(shared) or {}).get("external"):
                errors.append(f"{name}: network {shared} must be external")


def main() -> int:
    errors: list[str] = []
    composes = {}
    for name in (LOCAL, DENNIS):
        try:
            composes[name] = load(name)
        except (OSError, yaml.YAMLError) as exc:
            errors.append(f"{name}: does not parse: {exc}")
    if len(composes) == 2:
        local, dennis = composes[LOCAL], composes[DENNIS]
        for name, compose in composes.items():
            check_site(name, compose, errors)
        ls, ds = local.get("services") or {}, dennis.get("services") or {}
        if set(ls) != set(ds):
            errors.append(f"services differ: local-only {sorted(set(ls) - set(ds))}, Dennis-only {sorted(set(ds) - set(ls))}")
        for sname in sorted(set(ls) & set(ds)):
            a, b = ls[sname], ds[sname]
            for key in SAME_KEYS:
                if a.get(key) != b.get(key):
                    errors.append(f"{sname}: {key} differs between local and Dennis")
            if sorted(a.get("secrets") or []) != sorted(b.get("secrets") or []):
                errors.append(f"{sname}: secrets differ between local and Dennis")
            ea, eb = env_of(a), env_of(b)
            for key in sorted((set(ea) | set(eb)) - SITE_KEYS):
                if ea.get(key) != eb.get(key):
                    errors.append(f"{sname}: env {key} differs between local and Dennis")
        if set(local.get("secrets") or {}) != set(dennis.get("secrets") or {}):
            errors.append("top-level secrets differ between local and Dennis")

    for err in errors:
        print(f"ERROR: {err}")
    if not errors:
        print(f"OK: {len(composes[LOCAL]['services'])} services, both composes pinned, limited and in lockstep")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
