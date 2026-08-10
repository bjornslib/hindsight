# Upstream bug report: native Ollama path breaks all `gpt-oss` models

**Target:** https://github.com/vectorize-io/hindsight/issues
**Affects:** `hindsight-api-slim/hindsight_api/engine/providers/openai_compatible_llm.py`, `_call_ollama_native`
**Observed on:** upstream/main @ `3a48b6e5b`, standalone Docker image, Ollama 11434, `gpt-oss:20b`

---

## Summary

`_call_ollama_native` unconditionally sets `"think": False` in the native `/api/chat` payload:

```python
"think": False,  # Disable thinking for reasoning models (qwen3.5, etc.)
```

`gpt-oss` models emit their reasoning through a separate `thinking` field. When thinking is
disabled they return HTTP 200 with an **empty `message.content`**. Hindsight then fails to parse
the empty string, and every affected call dies with:

```
JSONDecodeError: Expecting value: line 1 column 1 (char 0)
```

The provider's own diagnostic confirms the empty body rather than a transport problem:

```
Model: ollama/gpt-oss:20b
Content length: 0 chars
Content preview: '<empty>'
```

## Blast radius

Not limited to one operation. The native path is used for structured output generally, so with a
`gpt-oss` model configured, **retain, consolidation and reflect all fail**. In our case the
background consolidator retried a backlog indefinitely, 4 attempts per batch:

```
WARNING - Ollama JSON parse error (attempt 4/4): Expecting value: line 1 column 1 (char 0)
ERROR   - Unexpected error during Ollama call: JSONDecodeError
WARNING - [CONSOLIDATION] LLM batch call failed (attempt 1/3) for 8 memories
INFO    - [WORKER_TASK] [STUCK?] op=... stage=llm.ollama_native.consolidation.attempt=1/4
```

It is silent in the sense that matters: the API is healthy, recall works, and only writes are
broken — so it presents as "consolidation is stuck", not as "the model is misconfigured".

## Reproduction

Idle Ollama, identical prompt and identical `format` schema, **only the `think` field differs**:

```bash
# BROKEN — content length 0
curl -s http://localhost:11434/api/chat -d '{
  "model":"gpt-oss:20b","stream":false,"think":false,
  "messages":[{"role":"user","content":"Consolidate these memories... Return structured JSON."}],
  "format":{"type":"object","properties":{"models":{"type":"array","items":{
    "type":"object","properties":{"title":{"type":"string"},"content":{"type":"string"}},
    "required":["title","content"]}}},"required":["models"]},
  "options":{"temperature":0.0}}'

# WORKS — content length 1308, valid schema-conforming JSON
#   same request with the "think" key omitted entirely
```

| Model | `think` | Result |
|---|---|---|
| `gpt-oss:20b` | `false` | `content` length **0** |
| `gpt-oss:20b` | omitted | `content` length **1308**, valid JSON |
| `qwen3.5:35b-a3b-coding-nvfp4` | `false` | works — presumably why it was hardcoded |

Note `"think": true` is not the fix either; the key must be **omitted**.

## Suggested fix

Make the field conditional on model family rather than unconditional — send `think: False` as
today for everything else, omit the key for `gpt-oss`. Matching should be case-insensitive and
cover `gpt-oss`, `gpt-oss:20b`, `gpt-oss:120b` and `<namespace>/gpt-oss...`, not an exact string
match on one tag.

A defensive improvement worth considering independently: treat an empty `message.content` from
the native path as an explicit, named error rather than letting it fall through to
`json.loads("")`. The current `JSONDecodeError` gives no hint that the model returned nothing,
which is what made this take a while to pin down.

## Environment

- upstream/main `3a48b6e5b`
- `pg0-embedded` 0.15.0, PostgreSQL 18.1.0
- standalone image, `HINDSIGHT_API_LLM_PROVIDER=ollama`, base URL `http://host.docker.internal:11434/v1`
- macOS host, Ollama serving `gpt-oss:20b` (12 GB VRAM)
