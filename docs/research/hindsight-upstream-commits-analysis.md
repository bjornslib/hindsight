# Hindsight Upstream Commits Analysis

**Date**: 2026-03-04
**Repository**: bjornslib/hindsight (upstream)
**Scope**: 8 commits spanning 2026-01-01 to 2026-03-02

---

## 1. Summary Table

| # | SHA (short) | Date | Message | Key Files Changed |
|---|-------------|------|---------|-------------------|
| 1 | `cab5a40f` | 2026-03-02 | feat: add Pydantic AI integration for persistent agent memory (#441) | `hindsight-integrations/pydantic-ai/` (new package: tools.py, config.py, errors.py, README, tests) |
| 2 | `3ffec650` | 2026-02-25 | feat: expand MCP tool surface area with 18 new tools and enhanced parameters (#435) | `mcp_tools.py` (+1482/-55), `mcp.py`, `test_mcp_tools.py` (+604), docs |
| 3 | `8d731f2e` | 2026-02-12 | feat: implement hierarchical configuration (system, tenant, bank) (#329) | `config.py` (+219), `config_resolver.py` (new, +274), `extensions/tenant.py`, control-plane UI, CLI, 47 files total |
| 4 | `f641b30d` | 2026-02-10 | feat: add mental model CRUD tools to MCP server (#337) | `mcp_tools.py` (+559), `memory_engine.py` (+45), `http.py` (-70 moved to engine), tests |
| 5 | `1240b826` | 2026-02-09 | 0.4.10 changelog | `changelog.md` (+25) |
| 6 | `9c3fda74` | 2026-01-31 | Add extension hooks for mental model operations (#260) | `operation_validator.py` (+103), `memory_engine.py` (+54), `http.py` (+39), tests (+206) |
| 7 | `522b71aa` | 2026-01-26 | doc: mental models (#199) | `mental-models.mdx` (new, +174), `reflect.mdx` (new, +216), CLAUDE.md, 65 files total (major docs rewrite) |
| 8 | `d49e8201` | 2026-01-01 | feat: add max_tokens and structured output to /reflect (#74) | `memory_engine.py` (+38), `llm_wrapper.py` (+27/-13), `http.py` (+25), clients, tests |

---

## 2. Mental Models

### What Mental Models Are (from commit 7 docs)

Mental models are **consolidated knowledge synthesized from multiple facts**. They are not individual memories but patterns, preferences, and learnings that emerge from accumulated evidence. The upstream documentation explicitly describes them as "pinned reflections."

**Data flow:**
```
New Facts --> Consolidation Engine --> {Existing Model? --> Refine Model, No --> Create Model} --> Mental Models
```

**Key properties:**
- Mental models are automatically created/updated by the consolidation engine after `retain()` operations
- They track supporting evidence (which facts contributed to the model)
- They handle contradictory evidence by preserving the full journey of how understanding evolved
- They have freshness awareness -- stale models are verified against current facts during reflect
- They support tag-based filtering

**Example from docs:**

| Raw Facts | Mental Model |
|-----------|--------------|
| "Alice prefers Python" | "Alice is a Python-focused developer who values readability and simplicity" |
| "Alice dislikes verbose code" | |
| "Alice recommends type hints" | |

### Mental Model CRUD via MCP (commit 4)

Six MCP tools were added for mental model management:
- `list_mental_models` -- List with optional tag filtering
- `get_mental_model` -- Get by ID (returns content, source_query, metadata)
- `create_mental_model` -- Create with async content generation
- `update_mental_model` -- Update name/source_query/tags
- `delete_mental_model` -- Delete by ID
- `refresh_mental_model` -- Re-run source query to update content

Both multi-bank (with `bank_id` param) and single-bank modes are supported, following the same pattern as retain/recall/reflect tools. The multi-bank variant returns JSON strings while the single-bank variant returns dicts.

**Architecture decision:** Mental model validation hooks (usage metering) were initially placed in HTTP handlers only. Commit 4 moved them into `memory_engine.py` so that MCP tools (which call engine methods directly, bypassing HTTP) also trigger validation. This follows the existing pattern for retain/recall/reflect.

### Mental Model Extension Hooks (commit 6)

Three new dataclasses and hook methods were added to `OperationValidatorExtension`:

```python
@dataclass
class MentalModelGetContext:
    bank_id: str
    mental_model_id: str
    request_context: RequestContext

@dataclass
class MentalModelGetResult:
    bank_id: str
    mental_model_id: str
    request_context: RequestContext
    output_tokens: int
    success: bool = True
    error: str | None = None

@dataclass
class MentalModelRefreshResult:
    bank_id: str
    mental_model_id: str
    request_context: RequestContext
    query_tokens: int
    output_tokens: int
    context_tokens: int
    facts_used: int
    mental_models_used: int
    success: bool = True
    error: str | None = None
```

Hook methods: `validate_mental_model_get()`, `on_mental_model_get_complete()`, `on_mental_model_refresh_complete()`.

The refresh hook receives detailed token counts and evidence counts (facts_used, mental_models_used) for billing/audit. The refresh task payload was updated to propagate `tenant_id` and `api_key_id` through the async task so extensions can attribute operations correctly.

### Mental Models in the Reflect Pipeline (commit 7 docs)

The reflect agent uses **hierarchical retrieval**:
1. **Reflections** -- User-curated summaries (highest priority, checked first)
2. **Mental Models** -- Consolidated knowledge with freshness awareness
3. **Raw Facts** -- Ground truth for verification

The reflect agent has access to these tools in its agentic loop:
- `search_reflections` -- User-curated summaries
- `search_mental_models` -- Consolidated knowledge
- `recall` -- Raw facts (ground truth)
- `expand` -- Get more context for a memory
- `done` -- Complete with final answer

The agent runs up to 10 iterations and must gather evidence before answering.

---

## 3. Multi-Bank Features

### Hierarchical Configuration (commit 3 -- major, 47 files)

This is the largest commit in the set. It introduces a three-tier configuration hierarchy:

```
Global (env vars) --> Tenant config (via extension) --> Bank config (database)
```

**Key components:**

1. **`StaticConfigProxy`** -- A proxy that wraps `HindsightConfig` and blocks access to bank-configurable fields. Raises `ConfigFieldAccessError` with a clear message directing developers to use `ConfigResolver.resolve_full_config(bank_id, context)`.

2. **`ConfigResolver`** (new file, 274 lines) -- Resolves configuration through the hierarchy:
   - `resolve_full_config(bank_id, context)` -- Returns complete `HindsightConfig` with all overrides applied. For internal use only.
   - `get_bank_config(bank_id, context)` -- Returns filtered config for API responses (excludes credentials, static fields, and respects tenant permissions).
   - `_load_bank_config(bank_id)` -- Loads bank-specific overrides from `banks.config` JSONB column.

3. **Field categorization** using `hierarchical()` and `static()` field markers:
   - Hierarchical fields can be overridden per-tenant/bank (e.g., `retain_chunk_size`, `retain_extraction_mode`, `enable_observations`)
   - Static fields are server-level only (e.g., database URL, API port)
   - Credential fields are never exposed via API

4. **Database migration** -- New `banks.config` JSONB column via Alembic.

5. **`TenantExtension`** additions:
   - `get_tenant_config(context)` -- Returns tenant-level config overrides
   - `get_allowed_config_fields(context, bank_id)` -- Returns which fields a tenant is allowed to configure (None = all)

6. **CLI commands**: `hindsight bank config`, `hindsight bank set-config`, `hindsight bank reset-config`

7. **Control plane UI** -- New `bank-config-view.tsx` component (480 lines) with dialog-based editing for bank-specific configuration.

**Security model:**
- `HINDSIGHT_API_ENABLE_BANK_CONFIG_API` env var (default: `false`) gates the bank config endpoints
- Credential fields are always excluded from API responses
- Tenant permissions further filter which fields are visible/editable
- Config is resolved on every request (no caching) to support multi-server deployments

**Pipeline changes:**
- The entire retain pipeline was updated to pass resolved config through the call chain: `memory_engine.py` -> `orchestrator.py` -> `fact_extraction.py` -> `utils.py`
- Consolidation now respects bank-specific `enable_observations` settings

### Multi-Bank MCP Patterns (commits 2 and 4)

The MCP tools consistently use a dual-mode pattern:
- **Multi-bank mode** (`include_bank_id_param=True`): Tools accept an optional `bank_id` parameter with default from session. Returns JSON strings.
- **Single-bank mode** (`include_bank_id_param=False`): No `bank_id` parameter, uses resolved session bank. Returns Python dicts.

Single-bank mode excludes multi-bank management tools: `list_banks`, `create_bank`, `get_bank_stats`.

---

## 4. Reflect / Reasoning Changes

### Structured Output and max_tokens (commit 8)

The `/reflect` endpoint gained two new parameters:

```python
class ReflectRequest(BaseModel):
    query: str
    budget: Budget = Budget.LOW
    context: str | None = None
    max_tokens: int = Field(default=4096)
    response_schema: dict | None = Field(default=None)
```

**How structured output works:**

1. When `response_schema` is provided, a `JsonSchemaWrapper` class is created that provides a `model_json_schema()` interface to the LLM wrapper.

2. The LLM wrapper (`llm_wrapper.py`) gained a `strict_schema` parameter:
   - **Strict mode** (`strict_schema=True`): Uses OpenAI's `json_schema` response format with `"strict": True`. Guarantees all required fields are returned.
   - **Soft mode** (`strict_schema=False`, the default for reflect): Adds schema to the system prompt and uses `json_object` mode. Avoids retrying forever on providers that don't support strict schemas.

3. When structured output is requested:
   - `structured_output` field in `ReflectResponse` contains the parsed JSON
   - `text` field is empty (for backward compatibility)
   - `skip_validation=True` is passed so raw JSON is returned without Pydantic validation

4. `ReflectResult` dataclass gained `structured_output: dict | None` field.

**The reflect scope was renamed from `"memory_think"` to `"memory_reflect"`**, and `max_completion_tokens` is now configurable (was hardcoded to 1000).

### Reflect Agent Architecture (commit 7 docs)

The reflect agent is an **agentic loop** system that:
- Runs up to 10 iterations of tool calls
- Has a guardrail preventing empty responses (must gather evidence first)
- Validates citations (only IDs actually retrieved can be cited)
- Applies the bank's disposition traits (skepticism, literalism, empathy on 1-5 scales) to shape reasoning
- Supports a natural language "mission" that influences what knowledge gets prioritized

### Enhanced MCP Reflect Tool (commit 2)

The MCP reflect tool gained new parameters:
- `budget` -- Previously hardcoded, now exposed as a parameter
- `response_schema` -- For structured output
- `tags` / `types` -- For filtering which memories to include

---

## 5. New MCP Tools

### Commit 2: 18 New Tools (+1482 lines to mcp_tools.py)

**Directive tools:**
- `list_directives` -- List directives for a bank
- `create_directive` -- Create a new directive
- `delete_directive` -- Delete a directive

**Memory browsing tools:**
- `list_memories` -- List memories with pagination
- `get_memory` -- Get a specific memory by ID
- `delete_memory` -- Delete a specific memory

**Document tools:**
- `list_documents` -- List documents for a bank
- `get_document` -- Get a specific document
- `delete_document` -- Delete a specific document

**Operation tools:**
- `list_operations` -- List async operations
- `get_operation` -- Get operation status
- `cancel_operation` -- Cancel a pending operation

**Tags & bank management tools:**
- `list_tags` -- List all tags used in a bank
- `get_bank` -- Get bank details
- `get_bank_stats` -- Get bank statistics (multi-bank only)
- `update_bank` -- Update bank settings
- `delete_bank` -- Delete a bank
- `clear_memories` -- Clear all memories from a bank

**Enhanced existing tool parameters:**
- `retain`: Added `tags`, `metadata`, `document_id` parameters
- `recall`: Added `budget`, `types`, `tags`, `tags_match` parameters (previously hardcoded)
- `reflect`: Added `budget`, `response_schema`, `tags`, `types` parameters
- Mental model tools: Added `tags`, `trigger` parameters

### Commit 4: 6 Mental Model Tools (+559 lines)

- `list_mental_models`, `get_mental_model`, `create_mental_model`, `update_mental_model`, `delete_mental_model`, `refresh_mental_model`

(Details in Mental Models section above.)

### Commit 1: Pydantic AI Integration (new package)

Not MCP tools per se, but a new integration package `hindsight-pydantic-ai` that provides:
- `create_hindsight_tools()` -- Factory returning retain/recall/reflect `Tool` instances for Pydantic AI agents
- `memory_instructions()` -- Auto-injects relevant memories via Agent instructions callable
- `configure()` / `get_config()` / `reset_config()` -- Global configuration management

Uses async-native Hindsight client (`aretain`, `arecall`, `areflect`) directly -- no thread-pool compatibility needed since Pydantic AI is async-native.

---

## 6. Extension System Changes

### Operation Validator Extensions for Mental Models (commit 6)

Added to `OperationValidatorExtension`:
- `validate_mental_model_get(ctx)` -- Pre-operation validation (can reject with `ValidationResult`)
- `on_mental_model_get_complete(result)` -- Post-GET hook for tracking/audit
- `on_mental_model_refresh_complete(result)` -- Post-refresh hook with detailed token and evidence counts

All hooks are optional (default implementations accept/no-op). Errors in post-operation hooks are logged as warnings but don't fail the operation.

### Hooks Moved from HTTP to Engine (commit 4)

Mental model validation hooks were moved from `http.py` to `memory_engine.py` so both HTTP and MCP paths trigger them. This removed 70 lines from `http.py` and added 45 lines to `memory_engine.py`. The `is_internal` check was added so background worker tasks skip billing.

### Tenant Extension Enhancements (commit 3)

`TenantExtension` gained two new methods:
- `get_tenant_config(context: RequestContext) -> dict | None` -- Returns tenant-level config overrides
- `get_allowed_config_fields(context: RequestContext, bank_id: str) -> set[str] | None` -- Permission-based field filtering

### MCP Tenant Authentication (noted in 0.4.10 changelog, commit 5)

The changelog mentions "TenantExtension authentication support for the MCP endpoint" was added in a related commit (not in this set but noted in the 0.4.10 release).

---

## 7. Key Architectural Patterns

### 1. Dual-Mode MCP Tool Registration

Every MCP tool is registered twice -- once with `bank_id` parameter (multi-bank) and once without (single-bank). The selection is driven by `config.include_bank_id_param`. Multi-bank tools return JSON strings; single-bank tools return Python dicts. This allows the same MCP server to work in both hosted multi-tenant and self-hosted single-tenant deployments.

### 2. Config Field Protection via Proxy

`StaticConfigProxy` blocks access to hierarchical fields from `get_config()`, forcing developers to use `resolve_full_config(bank_id, context)`. This is a compile-time-like safety net that prevents accidentally using global defaults when bank-specific overrides exist. The proxy raises `ConfigFieldAccessError` with actionable messages.

### 3. Validation at Engine Level, Not HTTP Level

The pattern established in commit 4 (and retroactively applied) is: operation validation/metering hooks belong in `memory_engine.py`, not in HTTP handlers. This ensures all access paths (HTTP, MCP, background workers) go through the same validation. Background workers set `is_internal=True` to skip billing.

### 4. Async Task Payload for Context Propagation

When an operation needs to run asynchronously (like mental model refresh), the task payload carries `_tenant_id` and `_api_key_id` so the worker can reconstruct a proper `RequestContext` for extension hooks. This is a clean pattern for maintaining context across async boundaries.

### 5. Hierarchical Config Without Caching

Config resolution happens on every request -- no caching. This ensures consistency across multi-server deployments (any server sees the latest bank overrides from the database). The LLM client pool was removed since LLM config is static (server-level), eliminating the need for per-bank LLM client management.

### 6. Schema Enforcement Strategy

Two modes for structured output:
- **Strict** (OpenAI only): `json_schema` with `"strict": True` -- guarantees field presence
- **Soft** (universal): Schema injected into system prompt + `json_object` response format

Reflect uses soft mode to avoid infinite retries on providers that don't support strict schemas.

### 7. Integration Pattern: Factory + Global Config

The Pydantic AI integration follows a clean pattern: `configure()` sets global defaults, factory functions (`create_hindsight_tools`, `memory_instructions`) use global config as fallback but allow per-call overrides. This matches the existing integration pattern used by other hindsight integrations.

---

## 8. Implications for Our PRD

### Multi-Bank Querying

1. **The hierarchical config system (commit 3) is foundational.** Our fork's multi-bank MCP access feature needs to be compatible with this three-tier configuration hierarchy. When querying across banks, each bank may have different config overrides that affect how retain/recall/reflect behaves.

2. **The dual-mode MCP pattern is well-established.** Our multi-bank querying should follow the same `include_bank_id_param` pattern. The upstream already supports cross-bank operations via optional `bank_id` parameters on every tool.

3. **Config resolution is per-request, per-bank.** If we aggregate results across banks, we need to resolve config separately for each bank involved in the query.

4. **The 18 new MCP tools (commit 2) significantly expand what's available.** Our multi-bank implementation needs to account for these new tools -- they all support the `bank_id` parameter pattern.

### Mental Models

1. **Mental models are already well-developed upstream.** Full CRUD via MCP, extension hooks for billing/validation, automatic consolidation, and integration into the reflect pipeline. We should leverage this rather than building our own.

2. **Mental models are "living documents"** -- they auto-refresh via `refresh_mental_model` which re-runs the source query. This means they stay current as new facts are retained. Cross-bank mental model awareness could be a differentiator.

3. **The consolidation engine is automatic and mission-aware.** The bank's mission influences what gets consolidated. This is important for our multi-bank design -- different banks with different missions will produce different mental models from the same facts.

4. **Mental models participate in the retrieval hierarchy** (reflections > mental models > raw facts). Our cross-bank querying needs to include mental models from all relevant banks.

### Multi-Step Reasoning

1. **Reflect is already an agentic loop** with up to 10 iterations, tool calls (search_reflections, search_mental_models, recall, expand, done), citation validation, and disposition-aware reasoning. This is more sophisticated than a simple RAG query.

2. **Structured output (commit 8) enables programmatic consumption of reflect results.** The `response_schema` + `max_tokens` parameters let callers shape the output format. Our multi-step reasoning could chain reflect calls with structured output.

3. **The `budget` parameter controls exploration depth.** Low/mid/high budgets map to different unit caps (100/300/600). Multi-step reasoning across banks would need budget management to avoid excessive costs.

4. **Disposition shapes reasoning consistently.** Each bank has persistent personality traits (skepticism, literalism, empathy). Cross-bank reasoning would need to decide how to reconcile different dispositions.

### Key Gaps Our PRD Should Address

1. **Cross-bank reflect:** Upstream reflect operates on a single bank. A cross-bank reflect would need to aggregate mental models and facts from multiple banks, potentially with different dispositions.

2. **Cross-bank mental model synthesis:** Currently mental models are per-bank. Synthesizing knowledge across banks is not supported upstream.

3. **Multi-bank config resolution for aggregated queries:** When recalling across banks, each bank's config (e.g., enabled fact types, tag scopes) may differ. The aggregation layer needs to handle this.

4. **Budget allocation across banks:** A single cross-bank query needs to allocate its budget across the participating banks.

5. **Extension hook propagation:** The operation validator extension hooks are bank-scoped. Cross-bank operations would trigger hooks per-bank, which may have billing implications.
