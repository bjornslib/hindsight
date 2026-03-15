# Cross-Bank Querying Patterns Research

**Date:** 2026-03-15
**Task:** research_crossbank
**PRD:** PRD-SECONDBRAIN-001
**SD:** SD-SECONDBRAIN-001 Epic 2

---

## Executive Summary

This research document explores patterns and best practices for implementing cross-bank querying in the Hindsight memory system. Cross-bank querying enables a single query to search across multiple isolated memory banks, fuse results using Reciprocal Rank Fusion (RRF), and synthesize responses using disposition-aware reasoning.

**Key Findings:**
1. RRF is the industry-standard algorithm for federated search fusion
2. Python asyncio with `asyncio.gather()` is ideal for parallel bank queries
3. Disposition reconciliation should use relevance-weighted averaging
4. Budget allocation strategies should support equal split, proportional, and relevance-based modes
5. Extension hooks should fire both per-bank and aggregate (cross-bank) levels

---

## 1. Current Architecture Analysis

### 1.1 Existing Bank Model

From `hindsight-api/hindsight_api/engine/retain/bank_utils.py`:

```python
class BankProfile(TypedDict):
    """Type for bank profile data."""
    name: str
    disposition: DispositionTraits  # skepticism, literalism, empathy (1-5 each)
    mission: str
```

**Key Observations:**
- Banks are isolated by `bank_id` as primary key
- Each bank has a unique disposition (skepticism, literalism, empathy)
- Banks auto-create on first access with default disposition (3, 3, 3)
- No cross-bank relationship model exists currently

### 1.2 Existing Recall Pipeline

From `hindsight-api/hindsight_api/engine/memory_engine.py`:

```python
async def recall_async(
    self,
    bank_id: str,
    query: str,
    *,
    budget: Budget | None = None,
    max_tokens: int = 4096,
    fact_type: list[str] | None = None,
    # ...
) -> RecallResultModel:
```

**Pipeline Steps:**
1. Tenant authentication
2. Fact type validation
3. Extension hook validation (`validate_recall`)
4. 4-way parallel retrieval (semantic, BM25, graph, temporal)
5. RRF fusion
6. Reranking
7. Token filtering

### 1.3 Existing Fusion Implementation

From `hindsight-api/hindsight_api/engine/search/fusion.py`:

```python
def reciprocal_rank_fusion(result_lists: list[list[RetrievalResult]], k: int = 60) -> list[MergedCandidate]:
    """
    Merge multiple ranked result lists using Reciprocal Rank Fusion.
    RRF formula: score(d) = sum_over_lists(1 / (k + rank(d)))
    """
```

**Current Usage:** Fusion is used internally within a single bank to combine 4 retrieval strategies. This same algorithm applies to cross-bank fusion.

---

## 2. Federated Search Patterns

### 2.1 Reciprocal Rank Fusion (RRF) - Industry Standard

**Sources:**
- [Azure AI Search - Hybrid Search Scoring (RRF)](https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking)
- [OpenSearch - Reciprocal Rank Fusion](https://opensearch.org/blog/introducing-reciprocal-rank-fusion-hybrid-search/)
- [Elasticsearch RRF Documentation](https://www.elastic.co/guide/en/elasticsearch/reference/current/rrf.html)
- [Weaviate - Hybrid Search Explained](https://weaviate.io/blog/hybrid-search-explained)

**Algorithm:**
```
score(d) = Σ 1/(k + rank(d))

Where:
- k = constant (typically 60)
- rank(d) = position of document in result list (1-based)
```

**Properties:**
- Score normalization not required (rank-based)
- Robust to score scale differences across banks
- Computationally inexpensive (real-time capable)
- Works well with heterogeneous sources

**Optimal k-value:**
- Research shows k=60 is optimal for most use cases
- Lower k (e.g., 1) gives more weight to top results
- Higher k (e.g., 100) flattens the curve

### 2.2 Cross-Bank Fusion Strategy

For cross-bank querying, we have two levels of fusion:

**Level 1: Within-Bank Fusion (existing)**
```
Bank A: [semantic_results, bm25_results, graph_results, temporal_results]
        → RRF → Bank A ranked list
```

**Level 2: Cross-Bank Fusion (new)**
```
[Bank A results, Bank B results, Bank C results]
→ RRF → Final ranked list
```

**Key Insight:** The same RRF algorithm works at both levels because:
1. Each bank's internal fusion produces a ranked list
2. Cross-bank fusion merges these ranked lists
3. RRF is rank-based, so score scale differences don't matter

---

## 3. Parallel Query Patterns

### 3.1 Python Asyncio Pattern

**Recommended Pattern:**
```python
import asyncio
from typing import Any

async def cross_bank_recall(
    query: str,
    bank_ids: list[str],
    engine: MemoryEngine,
    budget_per_bank: int,
) -> list[tuple[str, RecallResultModel]]:
    """Execute parallel recalls across banks."""

    async def recall_single(bank_id: str) -> tuple[str, RecallResultModel]:
        result = await engine.recall_async(
            bank_id=bank_id,
            query=query,
            budget=budget_per_bank,
            request_context=RequestContext(),
        )
        return (bank_id, result)

    # Parallel execution with asyncio.gather
    tasks = [recall_single(bid) for bid in bank_ids]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    # Filter out exceptions
    successful = [
        r for r in results
        if not isinstance(r, Exception)
    ]

    return successful
```

**Key Considerations:**
1. Use `return_exceptions=True` to handle partial failures gracefully
2. Each bank gets its own connection from the pool
3. Connection acquisition should happen per-bank, not held during LLM calls
4. Budget must be divided across banks before parallel execution

### 3.2 Connection Pool Management

From the existing architecture, connection pools are managed at the engine level:

```python
pool = await self._get_pool()
async with pool.acquire() as conn:
    # Database operations here
```

**For Cross-Bank:**
- Don't hold connections during LLM calls
- Each bank query acquires its own connection
- Use separate connection for aggregation/fusion step

### 3.3 Budget Allocation Strategies

**Equal Split (default):**
```python
def equal_split(total_budget: int, n_banks: int) -> dict[str, int]:
    per_bank = total_budget // n_banks
    return {bank_id: per_bank for bank_id in bank_ids}
```

**Proportional to Bank Size:**
```python
async def proportional_split(
    total_budget: int,
    bank_ids: list[str],
    pool,
) -> dict[str, int]:
    # Get memory count per bank
    sizes = await get_bank_sizes(pool, bank_ids)
    total = sum(sizes.values())
    return {
        bid: int(total_budget * (sizes[bid] / total))
        for bid in bank_ids
    }
```

**Relevance-Based (pre-query):**
```python
async def relevance_split(
    total_budget: int,
    query: str,
    bank_ids: list[str],
    engine: MemoryEngine,
) -> dict[str, int]:
    # Lightweight BM25-only pre-query to estimate relevance
    estimates = await estimate_relevance(engine, query, bank_ids)
    total_rel = sum(estimates.values())
    return {
        bid: int(total_budget * (estimates[bid] / total_rel))
        for bid in bank_ids
    }
```

---

## 4. Disposition Reconciliation Patterns

### 4.1 The Problem

When querying multiple banks with different dispositions, how do we synthesize a response that respects the different "personalities"?

**Example:**
- Bank A: skepticism=5, literalism=3, empathy=1 (skeptical, detached)
- Bank B: skepticism=1, literalism=5, empathy=5 (trusting, literal, empathetic)
- Query: "What should I do about X?"

### 4.2 Relevance-Weighted Averaging (Recommended)

```python
@dataclass
class Disposition:
    skepticism: float
    literalism: float
    empathy: float

    def __add__(self, other: "Disposition") -> "Disposition":
        return Disposition(
            skepticism=self.skepticism + other.skepticism,
            literalism=self.literalism + other.literalism,
            empathy=self.empathy + other.empathy,
        )

    def __mul__(self, weight: float) -> "Disposition":
        return Disposition(
            skepticism=self.skepticism * weight,
            literalism=self.literalism * weight,
            empathy=self.empathy * weight,
        )

def reconcile_dispositions(
    bank_results: dict[str, list[Fact]],
    bank_dispositions: dict[str, Disposition],
) -> Disposition:
    """Weight each bank's disposition by result contribution."""
    total_facts = sum(len(facts) for facts in bank_results.values())
    if total_facts == 0:
        return Disposition.neutral()

    weighted = Disposition.zero()
    for bank_id, facts in bank_results.items():
        weight = len(facts) / total_facts
        weighted = weighted + bank_dispositions[bank_id] * weight

    return weighted
```

### 4.3 LLM Prompt for Disposition-Aware Synthesis

```python
CROSS_BANK_REFLECT_PROMPT = """You are synthesizing knowledge from {n_banks} memory banks.

Bank Profiles:
{bank_profiles}

Each bank has a different disposition (skepticism, literalism, empathy on 1-5 scale).
The aggregated disposition for this query is:
- Skepticism: {skepticism:.1f}/5
- Literalism: {literalism:.1f}/5
- Empathy: {empathy:.1f}/5

Facts from banks:
{facts_with_attribution}

Instructions:
1. Answer the question using the facts above
2. Attribute facts to their source banks: [Bank: X]
3. If banks have conflicting information, note the conflict
4. Match your tone to the aggregated disposition
5. Be concise and actionable

Question: {query}
"""
```

---

## 5. Extension Hook Patterns for Cross-Bank

### 5.1 Current Extension Model

From `hindsight-api/hindsight_api/extensions/operation_validator.py`:

```python
@dataclass
class RecallContext:
    bank_id: str
    query: str
    request_context: "RequestContext"
    budget: "Budget | None" = None
    # ...

@dataclass
class RecallResult:
    bank_id: str
    query: str
    request_context: "RequestContext"
    # Result fields...
```

### 5.2 Proposed Cross-Bank Hooks

```python
@dataclass
class CrossBankRecallContext:
    """Pre-validation context for cross-bank recall."""
    bank_ids: list[str]
    query: str
    budget: Budget
    request_context: RequestContext

@dataclass
class CrossBankRecallResult:
    """Post-operation context for cross-bank recall."""
    bank_ids: list[str]
    query: str
    results_per_bank: dict[str, int]
    total_results: int
    request_context: RequestContext
    success: bool = True
    error: str | None = None

@dataclass
class CrossBankReflectContext:
    """Pre-validation context for cross-bank reflect."""
    bank_ids: list[str]
    query: str
    budget: Budget
    include_mental_models: bool
    request_context: RequestContext

@dataclass
class CrossBankReflectResult:
    """Post-operation context for cross-bank reflect."""
    bank_ids: list[str]
    query: str
    facts_per_bank: dict[str, int]
    mental_models_per_bank: dict[str, int]
    reasoning_steps: int
    output_tokens: int
    request_context: RequestContext
    success: bool = True
    error: str | None = None
```

### 5.3 Hook Execution Order

```
cross_bank_reflect(bank_ids=["A", "B"])
  │
  ├─► validate_cross_bank_reflect (pre, once)
  │
  ├─► validate_recall for Bank A (pre, per-bank)
  ├─► validate_recall for Bank B (pre, per-bank)
  │
  ├─► [execution - parallel recalls]
  │
  ├─► on_recall_complete for Bank A (post, per-bank)
  ├─► on_recall_complete for Bank B (post, per-bank)
  │
  ├─► [execution - synthesis LLM call]
  │
  └─► on_cross_bank_reflect_complete (post, once with aggregated stats)
```

**Key Insight:** This ensures per-bank billing is accurate while providing aggregate metrics.

---

## 6. Bank Selection Strategies

### 6.1 Explicit Bank IDs

```python
result = await cross_bank_recall(
    query="What are my current projects?",
    bank_ids=["work-bank", "personal-bank"],
    ...
)
```

### 6.2 Tag-Based Selection

Add `tags` column to `banks` table:

```sql
ALTER TABLE banks ADD COLUMN tags TEXT[] DEFAULT '{}';
CREATE INDEX idx_banks_tags ON banks USING GIN(tags);
```

Query by tag:
```python
result = await cross_bank_recall(
    query="What meetings do I have?",
    bank_tags=["calendar", "work"],
    ...
)
```

### 6.3 All Accessible Banks

```python
result = await cross_bank_recall(
    query="What do I know about X?",
    bank_ids=None,  # All accessible banks
    ...
)
```

**Access Control:** Extension hook `filter_bank_list` can filter accessible banks based on user context.

---

## 7. Response Model Design

### 7.1 Cross-Bank Fact Model

```python
class CrossBankFact(BaseModel):
    """A fact with bank attribution."""
    id: str
    text: str
    fact_type: str
    bank_id: str
    bank_name: str | None = None
    context: str | None = None
    confidence: float | None = None
    occurred_start: datetime | None = None
    rrf_score: float | None = None  # Cross-bank RRF score
    source_ranks: dict[str, int] | None = None  # Rank in each bank's results
```

### 7.2 Cross-Bank Recall Result

```python
class CrossBankRecallResult(BaseModel):
    """Result from cross-bank recall."""
    results: list[CrossBankFact]
    bank_stats: dict[str, int]  # bank_id -> fact count
    fusion_metadata: dict  # RRF weights, dedup counts
    total_results: int
```

### 7.3 Cross-Bank Reflect Result

```python
class CrossBankReflectResult(BaseModel):
    """Result from cross-bank reflect."""
    text: str
    based_on: list[CrossBankFact]
    mental_models_used: list[MentalModelReference]
    bank_dispositions: dict[str, dict]  # bank_id -> disposition
    structured_output: dict | None = None
    reasoning_chain: list[dict] | None = None  # If multi-step
    new_opinions: list[dict] = []
```

---

## 8. Risk Mitigation Strategies

### 8.1 Latency Management

**Problem:** Cross-bank queries could take 10+ seconds if banks are slow.

**Mitigations:**
1. **Budget limits:** Lower per-bank budget when querying many banks
2. **Early termination:** Stop after N results found
3. **Timeout per bank:** Set maximum time per bank query
4. **Parallel execution:** All banks queried simultaneously

```python
async def recall_with_timeout(bank_id: str, timeout: float = 5.0):
    try:
        return await asyncio.wait_for(
            recall_single(bank_id),
            timeout=timeout
        )
    except asyncio.TimeoutError:
        return (bank_id, None)  # Empty results for timed-out bank
```

### 8.2 Schema Isolation

**Problem:** Cross-bank queries must not leak data between schemas.

**Mitigation:**
- No cross-schema SQL queries
- All cross-bank operations in Python orchestration layer
- Each bank query uses its own connection with proper schema context

### 8.3 Budget Exhaustion

**Problem:** Multi-step reasoning could exhaust budget before synthesis.

**Mitigation:**
```python
class ReasoningBudgetManager:
    SYNTHESIS_RESERVE = 0.30  # Reserve 30% for final synthesis

    def allocate(self, total: int, n_steps: int) -> tuple[list[int], int]:
        synthesis = int(total * self.SYNTHESIS_RESERVE)
        remaining = total - synthesis
        per_step = remaining // n_steps
        return [per_step] * n_steps, synthesis
```

---

## 9. Implementation Recommendations

### 9.1 Phase 1: Core Cross-Bank Module

Create `hindsight_api/engine/cross_bank.py`:

1. `CrossBankOrchestrator` class
2. `cross_bank_recall()` method
3. `cross_bank_reflect()` method
4. Budget allocation logic
5. Disposition reconciliation

### 9.2 Phase 2: HTTP Endpoints

Add to `hindsight_api/api/http.py`:

```
POST /v1/default/cross-bank/recall
POST /v1/default/cross-bank/reflect
```

### 9.3 Phase 3: MCP Tools

Add to `hindsight_api/api/mcp_tools.py`:

```python
@mcp_tool
async def cross_bank_recall(query: str, bank_ids: list[str] | None = None, ...) -> str:
    """Search across multiple banks with fused ranking."""

@mcp_tool
async def cross_bank_reflect(query: str, bank_ids: list[str] | None = None, ...) -> str:
    """Reflect across multiple banks with disposition-aware synthesis."""
```

### 9.4 Phase 4: Extension Hooks

Add to `hindsight_api/extensions/operation_validator.py`:

- `CrossBankRecallContext` / `CrossBankRecallResult`
- `CrossBankReflectContext` / `CrossBankReflectResult`
- `validate_cross_bank_recall()` method
- `on_cross_bank_recall_complete()` method

---

## 10. References

### 10.1 RRF Documentation
- [Azure AI Search - Hybrid Search Scoring](https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking)
- [OpenSearch RRF Introduction](https://opensearch.org/blog/introducing-reciprocal-rank-fusion-hybrid-search/)
- [Elasticsearch RRF Reference](https://www.elastic.co/guide/en/elasticsearch/reference/current/rrf.html)
- [Weaviate Hybrid Search](https://weaviate.io/blog/hybrid-search-explained)

### 10.2 Internal Code References
- `hindsight-api/hindsight_api/engine/search/fusion.py` - Existing RRF implementation
- `hindsight-api/hindsight_api/engine/memory_engine.py` - Recall and reflect methods
- `hindsight-api/hindsight_api/engine/retain/bank_utils.py` - Bank profile management
- `hindsight-api/hindsight_api/extensions/operation_validator.py` - Extension hooks
- `hindsight-api/hindsight_api/alembic/versions/5a366d414dce_initial_schema.py` - Database schema

---

## Appendix A: Data Model Changes Required

### A.1 Banks Table Migration

```sql
-- Add tags column for bank selection
ALTER TABLE banks ADD COLUMN IF NOT EXISTS tags TEXT[] DEFAULT '{}';
CREATE INDEX IF NOT EXISTS idx_banks_tags ON banks USING GIN(tags);
```

### A.2 Reasoning Chains Table (for Epic 3)

```sql
CREATE TABLE reasoning_chains (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bank_id TEXT NOT NULL,       -- Primary bank (or 'cross-bank')
    original_query TEXT NOT NULL,
    steps JSONB NOT NULL,        -- Array of ReasoningStep
    final_text TEXT,
    total_budget_used INT,
    banks_consulted TEXT[] DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_reasoning_chains_bank_id ON reasoning_chains(bank_id);
CREATE INDEX idx_reasoning_chains_created_at ON reasoning_chains(created_at);
```