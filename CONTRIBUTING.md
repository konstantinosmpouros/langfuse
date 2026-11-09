# Contributing

This repo is configuration, not code: two compose files, a few scripts and
their CI. Changes are welcome as pull requests against `main`.

## Ground rules

1. **No secrets in the repo, ever** — not in compose files, not in examples,
   not in issue text. Secrets are files under `secrets/` (gitignored) or
   `/opt/langfuse/secrets/` on the host.
2. **Change both compose files together.** `docker-compose.yaml` (local) and
   `docker-compose-denis.yaml` (production) must stay in lockstep; only paths,
   the public URL, the local UI port and the networks may differ.
   `ci/check_config.py` enforces it.
3. **Pin images as `tag@sha256:<digest>`**, choose releases at least two weeks
   old, and check the `linux/arm64` manifest (production is ARM64):
   `docker buildx imagetools inspect <image:tag>`.
4. **LF line endings** everywhere (`.gitattributes` and CI enforce it).
5. **Conventional Commit titles**: `type(scope): subject` — e.g.
   `fix(clickhouse): raise the memory limit`. No `!`.

## Before opening a PR

```sh
scripts/gen-secrets.sh ./secrets you@example.com   # once
docker compose up -d                               # all services (healthy)
pip install "langfuse==4.18.0" "PyYAML==6.0.2" "yamllint==1.35.1"
python ci/check_config.py; echo $?                 # must print 0
yamllint --strict .; echo $?
python ci/smoke_trace.py; echo $?                  # trace sent, masked, read back
```

CI runs the same checks plus shellcheck, an ARM64 manifest check, a Trivy scan
of every pinned image and the smoke test on a fresh stack.

## Reporting bugs and vulnerabilities

Bugs: open an issue (template provided). Vulnerabilities: see
[SECURITY.md](SECURITY.md) — never a public issue.

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE).
