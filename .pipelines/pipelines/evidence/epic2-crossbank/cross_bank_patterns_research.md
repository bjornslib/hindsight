# Cross-Bank Implementation Patterns Research

**Date**: 2026-03-15
**Task**: Research cross-bank patterns for Epic 2 of SD-SECONDBRAIN-001
**Status**: Complete

## Executive Summary

This research identifies the key patterns and integration points required to implement the `CrossBankOrchestrator` module. The Hindsight memory system uses a **strict multi-tenant architecture** with PostgreSQL schema isolation, where each bank operates in complete isolation. The current implementation supports only single-bank operations, making cross-bank querying a significant architectural addition.

---

## 1. Schema Isolation Pattern

### Core Mechanism
The system uses PostgreSQL schemas for multi-tenant isolation via `contextvars`:

```python
# memory_engine.py (lines 80-100)
_current_schema: contextvars.ContextVar[str | None] = contextvars.ContextVar("current_schema", default=None)

def get_current_schema() -> str:
    schema = _current_schema.get()
    if schema is None:
        return get_config().database_schema
    return schema

def fq_table(table_name: str) -> str:
    return f"{get_current_schema()}.{table_name}"
```

### Protected Tables (Schema-Isolated)
```python
_PROTECTED_TABLES = frozenset([
    "memory_units", "memory_links", "unit_entities", "entities",
    "entity_cooccurrences", "banks", "documents", "chunks",
    "async_operations", "file_storage",
])
```

### Cross-Bank Implication
Cross-bank queries must either:
1. **Switch schemas per query** using contextvar tokens
2. **Use fully-qualified table names** with explicit schema prefixes
3. **Execute in parallel with different schema contexts**

---

## 2. Current Single-Bank Operations

### Recall Operation (`recall_async`)
**Location**: `memory_engine.py` line 1895

**Signature**:
```python
async def recall_async(
    self,
    bank_id: str,
    query: str,
    *,
    budget: Budget | None = None,
    max_tokens: int = 4096,
    fact_type: list[str] | None = None,
    tags: list[str] | None = None,
    tags_match: TagsMatch = "any",
    request_context: "RequestContext",
    ...
) -> RecallResultModel
```

**Implementation Pattern**:
1. Authenticate tenant and set schema: `await self._authenticate_tenant(request_context)`
2. Validate operation permissions
3. Map budget enum to thinking budget
4. Execute 4-way parallel retrieval:
   - Semantic (vector similarity)
   - BM25 (keyword search)
   - Graph (entity/relationship traversal)
   - Temporal (time-aware search)
5. Merge via Reciprocal Rank Fusion (RRF)
6. Rerank and diversify

### Reflect Operation (`reflect_async`)
**Location**: `memory_engine.py` line 4388

**Signature**:
```python
async def reflect_async(
    self,
    bank_id: str,
    query: str,
    *,
    budget: Budget | None = None,
    context: str | None = None,
    max_tokens: int = 4096,
    response_schema: dict | None = None,
    tags: list[str] | None = None,
    tags_match: TagsMatch = "any",
    request_context: "RequestContext",
) -> ReflectResult
```

**Implementation Pattern**:
1. Get bank profile for agent identity
2. Load directives (hard rules for responses)
3. Compute max iterations based on budget
4. Run agentic loop with tools:
   - `lookup`: Search mental models
   - `recall`: Search facts
   - `learn`: Create/update mental models
   - `expand`: Get chunk/document context

### MCP Tools (Single-Bank)
**Location**: `mcp_tools.py`

```python
# recall (lines 428-505)
async def recall(query, max_tokens=4096, budget="high", ..., bank_id=None)

# reflect (lines 548-645)
async def reflect(query, context=None, budget="low", ..., bank_id=None)
```

Both tools take a single `bank_id` parameter.

---

## 3. Hierarchical Configuration System

### ConfigResolver
**Location**: `config_resolver.py`

**Resolution Order**:
1. Global config (environment variables)
2. Tenant config (via TenantExtension)
3. Bank config (database JSONB column)

```python
class ConfigResolver:
    async def resolve_full_config(self, bank_id: str, context: RequestContext) -> HindsightConfig:
        # Start with global config
        config_dict = asdict(self._global_config)

        # Apply tenant overrides
        if self.tenant_extension and context:
            tenant_overrides = await self.tenant_extension.get_tenant_config(context)
            config_dict.update(normalized_tenant)

        # Apply bank overrides
        bank_overrides = await self._load_bank_config(bank_id)
        config_dict.update(bank_overrides)

        return HindsightConfig(**config_dict)

    async def get_bank_config(self, bank_id: str, context: RequestContext) -> dict[str, Any]:
        # Returns filtered config (excludes credentials, static fields)
```

### Cross-Bank Implication
Cross-bank operations must:
1. Resolve config per bank independently
2. Handle different LLM providers/keys per bank
3. Merge results respecting per-bank settings

---

## 4. Bank Profile & Disposition

### BankProfile Structure
**Location**: `retain/bank_utils.py`

```python
class BankProfile(TypedDict):
    name: str
    disposition: DispositionTraits
    mission: str
```

### DispositionTraits
**Location**: `response_models.py` line 103, `api/http.py` line 770

```python
class DispositionTraits(BaseModel):
    skepticism: int = Field(ge=1, le=5)  # 1=trusting, 5=skeptical
    literalism: int = Field(ge=1, le=5)  # 1=interpretive, 5=literal
    empathy: int = Field(ge=1, le=5)     # 1=analytical, 5=empathic
```

### Disposition Usage
- **Only affects `reflect`** operation (not recall)
- Retrieved via `get_bank_profile(pool, bank_id)`
- Can be overridden per-bank via config

### Cross-Bank Disposition Reconciliation
For cross-bank reflect, need to:
1. Collect dispositions from all participating banks
2. Either:
   - **Average traits**: `(sum(skepticism) / n, sum(literalism) / n, sum(empathy) / n)`
   - **Weighted by bank relevance**: Higher weight for banks with more matching results
   - **User-selected dominant bank**: Use one bank's disposition

---

## 5. Retrieval Architecture

### 4-Way Parallel Retrieval
**Location**: `search/retrieval.py`

```python
@dataclass
class ParallelRetrievalResult:
    semantic: list[RetrievalResult]
    bm25: list[RetrievalResult]
    graph: list[RetrievalResult]
    temporal: list[RetrievalResult] | None
    timings: dict[str, float]
```

### Graph Retrievers (Pluggable)
1. **MPFP**: Multi-Path Fact Propagation
2. **BFS**: Breadth-First Search
3. **LinkExpansion**: Entity link traversal

### Cross-Bank Retrieval Strategy
For cross-bank queries:
1. Execute parallel retrieval per bank
2. Collect results from all banks
3. Apply cross-bank RRF fusion
4. Re-rank across combined result set

---

## 6. Mental Models

### Types
**Location**: `mental_models/__init__.py`

```python
class MentalModelSubtype(str, Enum):
    SYNTHESIZED_KNOWLEDGE = "synthesized_knowledge"  # Auto-generated from consolidation
    PINNED_REFLECTION = "pinned_reflection"          # User-curated living documents
```

### Mental Model Structure
```python
class MentalModel(BaseModel):
    id: str
    subtype: MentalModelSubtype
    title: str
    content: str
    tags: list[str]
    created_at: datetime
    updated_at: datetime
```

### Cross-Bank Mental Model Integration
- Mental models are bank-isolated
- Cross-bank reflect should search mental models from all banks
- Synthesis may need to reconcile conflicting mental models

---

## 7. Database Utilities

### Connection Management with Retry
**Location**: `db_utils.py`

```python
RETRYABLE_EXCEPTIONS = (
    asyncpg.exceptions.InterfaceError,
    asyncpg.exceptions.ConnectionDoesNotExistError,
    asyncpg.exceptions.TooManyConnectionsError,
    asyncpg.exceptions.DeadlockDetectedError,
    OSError,
    ConnectionError,
    asyncio.TimeoutError,
)

async def retry_with_backoff(func, max_retries=3, base_delay=0.5, max_delay=5.0)

@asynccontextmanager
async def acquire_with_retry(pool: asyncpg.Pool, max_retries=3)
```

### Cross-Bank Connection Handling
- Use existing retry utilities
- Consider semaphore for concurrent bank queries
- Pool contention monitoring already in place

---

## 8. Key Files for Implementation

| File | Purpose | Cross-Bank Relevance |
|------|---------|---------------------|
| `memory_engine.py` | Core engine | Primary integration point |
| `config_resolver.py` | Hierarchical config | Per-bank config resolution |
| `retain/bank_utils.py` | Bank profile utils | get_bank_profile, disposition |
| `search/retrieval.py` | 4-way retrieval | Parallel retrieval pattern |
| `search/fusion.py` | RRF fusion | Cross-bank result merging |
| `search/reranking.py` | Cross-encoder reranking | Re-rank combined results |
| `db_utils.py` | Connection utilities | Retry logic, pool management |
| `mcp_tools.py` | MCP tool interface | API surface changes |

---

## 9. Recommended CrossBankOrchestrator Design

### Location
`hindsight_api/engine/cross_bank/` (new module)

### Core Components

```
cross_bank/
├── __init__.py
├── orchestrator.py      # CrossBankOrchestrator class
├── retrieval.py         # Parallel bank retrieval
├── fusion.py           # Cross-bank RRF fusion
├── disposition.py      # Disposition reconciliation
└── config.py           # Cross-bank config resolution
```

### Key Methods

```python
class CrossBankOrchestrator:
    async def recall_multi_bank(
        self,
        bank_ids: list[str],
        query: str,
        *,
        budget_allocation: BudgetAllocation = "equal_split",
        fusion_strategy: FusionStrategy = "rrf",
        ...
    ) -> CrossBankRecallResult

    async def reflect_multi_bank(
        self,
        bank_ids: list[str],
        query: str,
        *,
        disposition_reconciliation: DispositionReconciliation = "average",
        ...
    ) -> CrossBankReflectResult
```

### Budget Allocation Strategies
```python
BudgetAllocation = Literal["equal_split", "proportional", "query_relevant"]
```

---

## 10. Implementation Considerations

### Authentication & Authorization
- Verify user has access to ALL requested banks
- Use existing `_operation_validator` pattern
- Tenant isolation must be preserved

### Performance
- Parallel bank queries using `asyncio.gather()`
- Connection pool management (semaphores)
- Result streaming for large result sets

### Error Handling
- Partial failures (some banks succeed, some fail)
- Timeout handling per bank
- Graceful degradation

### Observability
- Tracing spans per bank
- Timing metrics per bank
- Cross-bank operation logging

---

## 11. API Surface Changes

### New Endpoints
```
POST /v1/default/banks/multi/recall
POST /v1/default/banks/multi/reflect
```

### Request Body
```json
{
  "banks": ["bank_alice", "bank_bob"],
  "query": "What do I know about project X?",
  "budget_allocation": "equal_split",
  "max_tokens": 4096
}
```

### Response Structure
```json
{
  "results": [...],
  "by_bank": {
    "bank_alice": {"count": 5, "tokens": 1500},
    "bank_bob": {"count": 3, "tokens": 900}
  },
  "fusion_metadata": {
    "strategy": "rrf",
    "k": 60
  }
}
```

---

## 12. Testing Strategy

### Unit Tests
- Disposition reconciliation algorithms
- Budget allocation calculations
- RRF fusion with mock results

### Integration Tests
- Cross-bank recall with real database
- Cross-bank reflect with multiple banks
- Error handling (missing bank, unauthorized bank)

### Performance Tests
- Concurrent bank query benchmarks
- Connection pool saturation tests

---

## Conclusion

The Hindsight memory system's strict schema isolation pattern provides a clean foundation for cross-bank operations. The key implementation challenges are:

1. **Schema switching** during parallel queries
2. **Disposition reconciliation** for cross-bank reflect
3. **Result fusion** across banks
4. **Per-bank configuration** resolution

The existing patterns (parallel retrieval, RRF fusion, retry logic) can be extended for cross-bank scenarios with appropriate architectural additions.