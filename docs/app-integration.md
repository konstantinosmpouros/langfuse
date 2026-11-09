# Connecting an app (magenticx, orthodoxai)

How an app's agents service sends traces to this Langfuse. The app-side wiring
lives in each app's own repo; this page is the contract.

## 1. Network and endpoint

| | Local | Dennis |
| --- | --- | --- |
| Network to join (external) | `langfuse` (bridge, created by this repo's compose) | `langfuse` (attachable overlay, created once by hand) |
| Base URL | `http://langfuse-web:3000` | `http://langfuse-web:3000` |
| Public UI | <http://localhost:3300> | <https://langfuse.magenticx.com> |

Only the agents service (the one that runs LangChain/LangGraph) should join
`langfuse`. Never send traces through the public hostname.

```yaml
# app compose / Swarm stack (sketch)
services:
  agents:
    networks: [backend, langfuse]
    environment:
      LANGFUSE_BASE_URL: http://langfuse-web:3000
      LANGFUSE_PUBLIC_KEY_FILE: /run/secrets/langfuse_public_key
      LANGFUSE_SECRET_KEY_FILE: /run/secrets/langfuse_secret_key
networks:
  langfuse:
    external: true
```

Keys are per Langfuse project (`magenticx`, `orthodoxai`): **Project settings →
API keys**. Store them as Swarm secrets of the app stack (e.g.
`magenticx_langfuse_public_key`, `magenticx_langfuse_secret_key`), never as
plain environment variables.

## 2. SDK

The server is Langfuse **v4**. Use the Python SDK **v4 (≥ 4.7, tested with
4.18.0) or v5** — both are supported by server v4; ≥ 4.7 is needed for
real-time visibility (older ones show traces with a ~15 min delay). Read traces
back with the v2 APIs (`/api/public/v2/observations`): v4 no longer fills the
legacy tables behind `/api/public/traces`.

## 3. Masking — mandatory

The Langfuse server stores what it receives. **Masking happens in the app,
before data leaves the process**, through the SDK's `mask` hook. Every app
must install at least this mask (the CI smoke test uses the same patterns and
proves they are applied):

```python
import re
from langfuse import Langfuse

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
    """Recursively mask every string in inputs, outputs and metadata."""
    if isinstance(data, str):
        return _mask_str(data)
    if isinstance(data, dict):
        return {k: mask(data=v) for k, v in data.items()}
    if isinstance(data, (list, tuple)):
        return [mask(data=v) for v in data]
    return data

langfuse = Langfuse(
    public_key=read_secret("LANGFUSE_PUBLIC_KEY_FILE"),
    secret_key=read_secret("LANGFUSE_SECRET_KEY_FILE"),
    base_url=os.environ["LANGFUSE_BASE_URL"],
    mask=mask,
)
```

- Add app-specific patterns (internal tokens, phone numbers, …) to the list.
- `mask` covers data set through the SDK and the LangChain `CallbackHandler`.
  Spans from **other** OpenTelemetry instrumentations that Langfuse exports
  need `mask_otel_spans=` as well (see the SDK docstring).
- Reuse the app's existing log-redaction rules where they exist, so logs and
  traces redact the same things.

## 4. LangChain / LangGraph

```python
from langfuse.langchain import CallbackHandler

handler = CallbackHandler()          # uses the Langfuse client created above
graph.invoke(
    inputs,
    config={
        "callbacks": [handler],
        "configurable": {"thread_id": thread_id},
        "metadata": {
            "langfuse_session_id": thread_id,   # session = LangGraph thread
            "langfuse_user_id": pseudonymous_user_id,  # never an e-mail
            "langfuse_tags": ["magenticx"],
        },
    },
)
```

## 5. One trace id with Grafana Tempo

The SDK is OpenTelemetry-based. Create the app's own `TracerProvider` (the one
that exports to Tempo) **before** `Langfuse(...)`: Langfuse then adds its span
processor to that global provider, so Langfuse and Tempo see the same W3C
`trace_id`. By default Langfuse exports only Langfuse/GenAI spans
(`should_export_span`), so HTTP/DB spans stay in Tempo only.

Grafana → Langfuse link (Tempo data source → *Trace to links*):

```text
https://langfuse.magenticx.com/project/<project-id>/traces/${__trace.traceId}
```

## 6. Retention

Trace content is deleted after 30 days (ClickHouse TTL on `events_full`,
`events_core`, traces, observations, scores and the topic tables; MinIO
lifecycle on the raw events). Do not rely on Langfuse for
anything that must live longer — datasets you create from traces are kept.
