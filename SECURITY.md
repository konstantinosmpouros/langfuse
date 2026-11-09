# Security policy

This repository is the deployment configuration for a self-hosted
[Langfuse](https://langfuse.com) instance. It contains no secrets: every
credential is generated on the host by `scripts/gen-secrets.sh` and never
committed.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through
[GitHub private vulnerability reporting](https://github.com/konstantinosmpouros/langfuse/security/advisories/new).
Include what is affected, how to reproduce it, and the impact you see. You get
an acknowledgement within 7 days.

Vulnerabilities in Langfuse itself belong upstream:
<https://github.com/langfuse/langfuse/security/policy>.

## Supported versions

Only the commit currently on `main` (what is deployed) is supported.

## Security model in short

| Control | How |
| --- | --- |
| Secrets | One file per secret, mounted read-only at `/run/secrets/*`; on the host owned by the one container uid that reads it (`0400`), in a `0711` root directory. Langfuse gets them through `scripts/secrets-env.sh`, so they never appear in `docker inspect`, compose output or the repo. |
| Network | Datastores and worker on an `internal` network with no route out. Only `langfuse-web` joins the shared `langfuse` network (apps → ingestion API) and NPM's `proxy` network (public UI). No host ports in production. |
| Least privilege | `no-new-privileges`, `cap_drop: ALL` everywhere (root-start datastores get back only CHOWN/DAC_OVERRIDE/FOWNER/SETUID/SETGID), per-container memory/CPU/PID limits. Langfuse uses a MinIO user limited to its one bucket, never the MinIO root credentials. |
| Accounts | Sign-up disabled; the single owner account and the first project are created headlessly; sessions expire after 12 h. |
| Data | Masking of secrets/e-mails happens in the apps before data leaves them (`docs/app-integration.md`). Trace content is deleted after 30 days (ClickHouse TTL + MinIO lifecycle). ClickHouse system logs are off except `query_log` (3-day TTL; needed by Langfuse v4, holds query text with parameter placeholders, not values). |
| Supply chain | Every image pinned `tag@sha256`, ≥ 2 weeks old, `linux/arm64` verified; Trivy blocks fixable CRITICAL CVEs; actions pinned by commit SHA; Dependabot with a 14-day cooldown. |
| Deploy | Owner-only CD over a Tailscale-only SSH path with a forced-command key that can deploy only commits on `main`. |

Known accepted risks are listed in `.trivyignore.yaml` (each with a reason and
an expiry date).
