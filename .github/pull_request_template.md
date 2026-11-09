## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] Both compose files changed together (`python ci/check_config.py` passes)
- [ ] New/updated images are pinned as `tag@sha256:…`, at least two weeks old, with a `linux/arm64` manifest
- [ ] No secret, e-mail address, hostname credential or key in the diff
- [ ] Local stack boots healthy (`docker compose up -d`) and `python ci/smoke_trace.py` passes
- [ ] Docs updated (README / docs/) if behaviour or setup changed
- [ ] Deploy impact noted below (re-create? one-time step on Dennis?)

## Deploy impact

<!-- e.g. "re-creates clickhouse (config change)", "none: docs only" -->
