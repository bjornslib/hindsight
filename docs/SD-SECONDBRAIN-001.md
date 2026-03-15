# SD-SECONDBRAIN-001: Solution Design — Hindsight Second Brain Memory Layer

**PRD:** PRD-SECONDBRAIN-001
**Status:** Draft (v0.3 — epic status updates, create_documents, bouncer deferral)
**Author:** System 3 Meta-Orchestrator
**Date:** 2026-03-15
**Version:** 0.3

---

## Table of Contents

0. [Epic 0: Sync Fork with Upstream](#0-epic-0-sync-fork-with-upstream)
1. [Architecture Overview](#1-architecture-overview)
2. [Epic 1: Merge Upstream Mental Models](#2-epic-1-merge-upstream-mental-models)
3. [Epic 2: Cross-Bank Querying](#3-epic-2-cross-bank-querying)
4. [Epic 3: Multi-Step Reasoning in Reflect](#4-epic-3-multi-step-reasoning-in-reflect)
5. [Data Model Changes](#5-data-model-changes)
6. [API Surface Changes](#6-api-surface-changes)
7. [Extension Hook Design](#7-extension-hook-design)
8. [Risk Analysis](#8-risk-analysis)
9. [Epic 4-6: Second Brain Building Blocks](#9-epic-4-6-second-brain-building-blocks)

---

## 0. Epic 0: Sync Fork with Upstream — COMPLETE

**Status:** COMPLETE (2026-03-15)

### What Was Done

Merged 230+ upstream commits (v0.1.16 → v0.4.15) into `feature/multi-bank-mcp-access`.

### Actual Merge Process

```bash
# 1. Stash local changes (docs, scripts, .claude/, .mcp.json)
git stash push -u -m "pre-merge: local changes and untracked files"

# 2. Fetch and merge upstream
git fetch origin main
git merge origin/main --no-edit
# Result: 1 conflict (mcp.py), .gitignore auto-merged

# 3. Resolve mcp.py conflict — accepted upstream (theirs)
git checkout --theirs hindsight-api/hindsight_api/api/mcp.py
git add hindsight-api/hindsight_api/api/mcp.py
# Rationale: Upstream's mcp_tools.py (2,704 lines, 28 tools) + register_mcp_tools()
# pattern is strictly superior to our inline tool implementations.
# Our branch's 5 inline tools are redundant — they exist in upstream's mcp_tools.py.

# 4. Complete merge
git commit --no-edit  # → 2f9d709c

# 5. Restore stashed files
git stash pop  # .gitignore conflict resolved (kept upstream's .claude ignore)
git stash drop

# 6. Commit local files
git add .gitignore docs/ scripts/ docker/standalone/start-all.sh
git commit  # → aa17ebd7
```

### Actual Conflict Resolution

| File | Conflict Regions | Resolution | Rationale |
|------|-----------------|------------|-----------|
| `api/mcp.py` | 9 regions | Accept upstream (theirs) | Our inline tools are in upstream's `mcp_tools.py`; upstream adds auth, dual MCP servers, tenant propagation, usage metering |
| `.gitignore` | 0 (auto-merged) | Auto | N/A |
| `.gitignore` (stash pop) | 1 region | Keep upstream + our additions | Upstream added `.claude` ignore; kept their version |

### Post-Merge Verification

- [x] `mcp.py` (452 lines) — syntax verified, imports `mcp_tools.register_mcp_tools()`
- [x] `mcp_tools.py` (2,704 lines) — syntax verified, 92 function definitions, 28 registered tools
- [x] No conflict markers in any file
- [x] Clean working tree after commit
- [ ] `uv run pytest tests/` — blocked by torch platform dependency (macOS, not merge-related)

---

## 1. Architecture Overview

### Current Architecture (Single-Bank)

```
Client (Claude Code / SDK / HTTP)
        │
        ▼
┌─────────────────────────────────┐
│        API Layer                │
│  ┌──────┐ ┌──────┐ ┌────────┐ │
│  │ HTTP │ │ MCP  │ │MCP     │ │
│  │      │ │      │ │Local   │ │
│  └──┬───┘ └──┬───┘ └───┬────┘ │
│     └────────┼─────────┘      │
│              ▼                 │
│     ┌────────────────┐        │
│     │ MemoryEngine   │        │
│     │                │        │
│     │ retain()       │        │
│     │ recall()       │        │
│     │ reflect_async()│        │
│     └───────┬────────┘        │
│             │                 │
│     ┌───────┴────────┐       │
│     │   PostgreSQL    │       │
│     │  (schema/bank)  │       │
│     │  + pgvector     │       │
│     └────────────────┘        │
└─────────────────────────────────┘
```

### Target Architecture (Multi-Bank + Multi-Step)

```
Client (Claude Code / SDK / HTTP)
        │
        ▼
┌─────────────────────────────────────────────────┐
│              API Layer                           │
│  ┌──────┐ ┌──────┐ ┌────────┐                  │
│  │ HTTP │ │ MCP  │ │MCP     │                  │
│  │      │ │      │ │Local   │                  │
│  └──┬───┘ └──┬───┘ └───┬────┘                  │
│     └────────┼─────────┘                        │
│              ▼                                   │
│  ┌───────────────────────────────────────┐      │
│  │     CrossBankOrchestrator (NEW)       │      │
│  │                                       │      │
│  │  cross_bank_recall()                  │      │
│  │  cross_bank_reflect()                 │      │
│  │  ┌─────────────────────────┐          │      │
│  │  │  ReasoningEngine (NEW)  │          │      │
│  │  │  decompose()            │          │      │
│  │  │  gather()               │          │      │
│  │  │  synthesize()           │          │      │
│  │  └─────────────────────────┘          │      │
│  └──────────────┬────────────────────────┘      │
│                 │                                │
│     ┌───────────┼───────────┐                   │
│     ▼           ▼           ▼                   │
│  ┌──────┐  ┌──────┐  ┌──────┐                  │
│  │Bank A│  │Bank B│  │Bank C│  (parallel)      │
│  │Engine│  │Engine│  │Engine│                   │
│  └──┬───┘  └──┬───┘  └──┬───┘                  │
│     │         │         │                       │
│  ┌──┴───┐ ┌──┴───┐ ┌──┴───┐                   │
│  │Schema│ │Schema│ │Schema│                    │
│  │  A   │ │  B   │ │  C   │                    │
│  └──────┘ └──────┘ └──────┘                    │
│                                                  │
│     ┌────────────────────────────────┐          │
│     │  MentalModelManager (NEW)      │          │
│     │  Integrated from upstream      │          │
│     │  + cross-bank synthesis        │          │
│     └────────────────────────────────┘          │
└─────────────────────────────────────────────────┘
```

---

## 2. Epic 1: Merge Upstream Mental Models — COMPLETE

**Status:** COMPLETE (2026-03-15) — Delivered automatically via Epic 0 upstream merge.

All mental model functionality arrived with the 230+ commit merge. No cherry-picking was needed. Key components now present in our fork:

| Component | File | Status |
|-----------|------|--------|
| Mental model CRUD methods | `engine/memory_engine.py` | Merged |
| Mental model MCP tools (6) | `mcp_tools.py` | Merged |
| Mental model extension hooks | `extensions/operation_validator.py` | Merged |
| Hierarchical reflect retrieval | `engine/search/think_utils.py` | Merged |
| Mental model consolidation | `engine/retain/orchestrator.py` | Merged |
| Structured output for reflect | `engine/memory_engine.py` | Merged |
| Directives system | `mcp_tools.py` + engine | Merged |
| `mental_models` SQL table + migrations | `alembic/versions/` | Merged |

The original cherry-pick strategy in SD v0.2 is superseded — full merge was cleaner and brought in all upstream improvements (v0.3.0 through v0.4.15).

---

## 3. Epic 2: Cross-Bank Querying

### New Module: `CrossBankOrchestrator`

**Location:** `hindsight_api/engine/cross_bank.py`

```python
class CrossBankOrchestrator:
    """Orchestrates queries across multiple Hindsight banks."""

    def __init__(self, engine: MemoryEngine, config_resolver: ConfigResolver | None = None):
        self.engine = engine
        self.config_resolver = config_resolver

    async def cross_bank_recall(
        self,
        query: str,
        bank_ids: list[str] | None = None,  # None = all accessible banks
        bank_tags: list[str] | None = None,  # Filter banks by tag
        max_results: int = 20,
        budget: Budget = Budget.MID,
        request_context: RequestContext | None = None,
    ) -> CrossBankRecallResult:
        """Recall facts from multiple banks with fused ranking."""
        ...

    async def cross_bank_reflect(
        self,
        query: str,
        bank_ids: list[str] | None = None,
        bank_tags: list[str] | None = None,
        budget: Budget = Budget.MID,
        context: str | None = None,
        include_mental_models: bool = True,
        include_reasoning_chain: bool = False,
        response_schema: dict | None = None,
        request_context: RequestContext | None = None,
    ) -> CrossBankReflectResult:
        """Reflect across multiple banks with disposition-aware synthesis."""
        ...
```

### Cross-Bank Recall Algorithm

```
1. Resolve bank list
   - If bank_ids provided: validate access, use directly
   - If bank_tags provided: filter banks by tag
   - If neither: list all accessible banks

2. Parallel recall (asyncio.gather)
   For each bank:
     a. Resolve bank config (hierarchical)
     b. Run recall with bank's config
     c. Tag results with bank_id

3. Fusion
   a. Reciprocal Rank Fusion across bank result lists
   b. Deduplicate entities (same entity in multiple banks → merge)
   c. Apply global max_results limit

4. Return CrossBankRecallResult
   - results: list[CrossBankFact]  # Each fact has bank_id
   - bank_stats: dict[str, int]    # Facts per bank
   - fusion_metadata: dict          # RRF weights, dedup counts
```

### Cross-Bank Reflect Algorithm

```
1. Resolve bank list (same as recall)

2. Gather evidence (parallel per bank)
   For each bank:
     a. Recall facts (with bank config)
     b. Search mental models (if include_mental_models)
     c. Get bank profile (disposition, background)

3. Fuse context
   a. RRF across bank recall results
   b. Collect all mental models with bank attribution
   c. Aggregate dispositions (weighted by result relevance)

4. Synthesize (single LLM call)
   System prompt includes:
     - Aggregated disposition description
     - All bank backgrounds (attributed)
     - "You are synthesizing knowledge from N memory banks"
   User prompt includes:
     - Fused facts (with [Bank: X] attribution)
     - Mental models (with [Bank: X] attribution)
     - Original query + context

5. Extract opinions (async, per originating bank)
   - New opinions attributed to the bank they're most relevant to
   - If unclear, attributed to a "cross-bank" synthetic scope

6. Return CrossBankReflectResult
   - text: str
   - based_on: list[CrossBankFact]
   - mental_models_used: list[MentalModelReference]
   - bank_dispositions: dict[str, Disposition]
   - structured_output: dict | None
   - reasoning_chain: list[ReasoningStep] | None  # If multi-step
```

### Bank Selection Strategies

```python
class BankSelector:
    """Resolves which banks participate in a cross-bank query."""

    async def resolve(
        self,
        bank_ids: list[str] | None = None,
        bank_tags: list[str] | None = None,
        request_context: RequestContext | None = None,
    ) -> list[BankInfo]:
        if bank_ids:
            return await self._validate_and_load(bank_ids, request_context)
        if bank_tags:
            return await self._filter_by_tags(bank_tags, request_context)
        return await self._all_accessible(request_context)
```

### Disposition Reconciliation Strategy

When banks have conflicting dispositions, use **relevance-weighted averaging**:

```python
def reconcile_dispositions(
    bank_results: dict[str, list[Fact]],
    bank_dispositions: dict[str, Disposition],
) -> Disposition:
    """Weight each bank's disposition by how many relevant facts it contributed."""
    total_facts = sum(len(facts) for facts in bank_results.values())
    if total_facts == 0:
        return Disposition.default()

    weighted = Disposition.zero()
    for bank_id, facts in bank_results.items():
        weight = len(facts) / total_facts
        disposition = bank_dispositions[bank_id]
        weighted += disposition * weight

    return weighted
```

### New HTTP Endpoints

```
POST /v1/default/cross-bank/recall
POST /v1/default/cross-bank/reflect
```

### New MCP Tools

```python
@mcp_tool
async def cross_bank_recall(
    query: str,
    bank_ids: list[str] | None = None,
    bank_tags: list[str] | None = None,
    max_results: int = 20,
    budget: str = "mid",
) -> str:
    """Search for memories across multiple banks with fused ranking."""
    ...

@mcp_tool
async def cross_bank_reflect(
    query: str,
    bank_ids: list[str] | None = None,
    bank_tags: list[str] | None = None,
    budget: str = "mid",
    context: str | None = None,
    include_mental_models: bool = True,
    response_schema: dict | None = None,
) -> str:
    """Reflect across multiple banks, synthesizing knowledge with disposition awareness."""
    ...

@mcp_tool
async def create_documents(
    contents: list[dict],
    document_name: str | None = None,
    tags: list[str] | None = None,
    bank_id: str | None = None,
) -> str:
    """Retain one or multiple text documents as a named document group.

    Analogous to the HTTP /files/retain endpoint but for MCP text content.
    Creates a document record, runs fact extraction, and builds knowledge graph.

    Args:
        contents: List of content items, each with:
            - content (str): The document text
            - context (str): Category (e.g., 'meeting-notes', 'research', 'journal')
            - tags (list[str], optional): Tags for this content item
            - metadata (dict, optional): Key-value metadata
        document_name: Human-readable name for the document group
        tags: Tags applied to the entire document
        bank_id: Target bank (defaults to session bank)
    """
    ...
```

### Budget Allocation Strategy

```python
class BudgetAllocator:
    """Allocates query budget across banks."""

    @staticmethod
    def equal_split(budget: Budget, n_banks: int) -> dict[str, int]:
        """Split budget equally."""
        per_bank = budget.value // n_banks
        return {f"bank_{i}": per_bank for i in range(n_banks)}

    @staticmethod
    def proportional(budget: Budget, bank_sizes: dict[str, int]) -> dict[str, int]:
        """Allocate proportional to bank memory count."""
        total = sum(bank_sizes.values())
        return {
            bank_id: int(budget.value * (size / total))
            for bank_id, size in bank_sizes.items()
        }

    @staticmethod
    def query_relevant(budget: Budget, bank_relevance: dict[str, float]) -> dict[str, int]:
        """Allocate based on estimated query relevance per bank."""
        # Uses a lightweight pre-query (BM25 only) to estimate relevance
        total = sum(bank_relevance.values())
        return {
            bank_id: int(budget.value * (rel / total))
            for bank_id, rel in bank_relevance.items()
        }
```

Default: `equal_split`. Configurable via `budget_strategy` parameter.

### Python SDK Methods

```python
# In hindsight-clients/python
class HindsightClient:
    async def across_banks_recall(
        self,
        query: str,
        bank_ids: list[str] | None = None,
        **kwargs,
    ) -> CrossBankRecallResult:
        """Recall from multiple banks."""
        ...

    async def across_banks_reflect(
        self,
        query: str,
        bank_ids: list[str] | None = None,
        **kwargs,
    ) -> CrossBankReflectResult:
        """Reflect across multiple banks."""
        ...
```

---

## 4. Epic 3: Multi-Step Reasoning in Reflect

### New Module: `ReasoningEngine`

**Location:** `hindsight_api/engine/reasoning.py`

```python
@dataclass
class ReasoningStep:
    step_number: int
    question: str
    relevant_banks: list[str]
    evidence: list[CrossBankFact]
    mental_models_consulted: list[str]
    conclusion: str
    confidence: float
    budget_used: int

@dataclass
class ReasoningChain:
    original_query: str
    steps: list[ReasoningStep]
    final_synthesis: str
    total_budget_used: int
    banks_consulted: list[str]

class ReasoningEngine:
    """Multi-step reasoning within the reflect pipeline."""

    def __init__(
        self,
        engine: MemoryEngine,
        cross_bank: CrossBankOrchestrator,
        llm: LLMWrapper,
    ):
        self.engine = engine
        self.cross_bank = cross_bank
        self.llm = llm

    async def reason(
        self,
        query: str,
        bank_ids: list[str],
        budget: Budget,
        context: str | None = None,
        max_steps: int = 4,
        request_context: RequestContext | None = None,
    ) -> ReasoningChain:
        """Execute multi-step reasoning."""
        ...
```

### Reasoning Algorithm

```
Phase 1: DECOMPOSE
─────────────────
Input: complex query + bank contexts
LLM call: "Break this query into 2-4 independent sub-questions.
           For each, indicate which knowledge domains (banks) are relevant."

Output: [
  {question: "What are the team dynamics?", banks: ["business"]},
  {question: "What are the Q1 goals?", banks: ["business", "personal"]},
  {question: "What tasks are currently in flight?", banks: ["business"]},
]

Budget allocation: Split remaining budget across sub-questions
  (reserve 30% for synthesis step)

Phase 2: GATHER (parallel)
──────────────────────────
For each sub-question:
  If single bank → reflect_async(bank, question, budget_fraction)
  If multi-bank → cross_bank_reflect(question, banks, budget_fraction)

  Store: {question, evidence, conclusion, confidence}

Phase 3: SYNTHESIZE
───────────────────
Input: original query + all intermediate conclusions + all evidence
LLM call: "Given these findings, answer the original question.
           Cite which findings support each point."

Output: final answer + reasoning chain

Phase 4: EXTRACT (async)
────────────────────────
- Extract new opinions from synthesis
- Update mental models if conclusions conflict with existing ones
- Store reasoning chain as metadata on the reflect operation
```

### Budget Management for Multi-Step

```python
class ReasoningBudgetManager:
    """Manages budget allocation across reasoning steps."""

    SYNTHESIS_RESERVE = 0.30  # Reserve 30% for final synthesis

    def allocate(self, total: int, n_steps: int) -> tuple[list[int], int]:
        """Returns (per_step_budgets, synthesis_budget)."""
        synthesis = int(total * self.SYNTHESIS_RESERVE)
        remaining = total - synthesis
        per_step = remaining // n_steps
        return [per_step] * n_steps, synthesis
```

### Budget-to-Depth Mapping

| Budget | Max Steps | Decomposition | Cross-Bank |
|--------|-----------|---------------|------------|
| LOW (100) | 1 | No decomposition (single-shot) | Yes, if bank_ids provided |
| MID (300) | 2 | Simple decomposition (2 sub-Qs) | Yes |
| HIGH (600) | 4 | Full decomposition + refinement | Yes, with relevance-based allocation |

### Integration with Existing Reflect

The `ReasoningEngine` wraps the existing reflect pipeline. For LOW budget, it's a pass-through (backward compatible). For MID/HIGH with multi-step enabled, it adds decomposition.

```python
# In memory_engine.py reflect_async()
async def reflect_async(self, bank_id, query, budget, ...):
    if budget == Budget.LOW or not multi_step_enabled:
        return await self._single_step_reflect(bank_id, query, budget, ...)
    else:
        return await self.reasoning_engine.reason(
            query=query,
            bank_ids=[bank_id],
            budget=budget,
            ...
        )
```

### Decomposition Prompt Template

```python
DECOMPOSE_PROMPT = """You are a reasoning planner. Break down this complex question
into 2-{max_steps} independent sub-questions that, when answered, would provide
sufficient evidence to answer the original question.

Original question: {query}

Available knowledge domains (banks):
{bank_descriptions}

For each sub-question, specify:
- The question itself (specific, answerable)
- Which knowledge domain(s) are most relevant
- Why this sub-question matters for the original question

Return JSON:
{{
  "sub_questions": [
    {{
      "question": "...",
      "relevant_banks": ["bank_id_1"],
      "rationale": "..."
    }}
  ]
}}
"""
```

---

## 5. Data Model Changes

### New Tables (Alembic Migration)

```sql
-- Mental models (from upstream, if not already present)
CREATE TABLE IF NOT EXISTS mental_models (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bank_id TEXT NOT NULL,
    name TEXT NOT NULL,
    source_query TEXT,
    content TEXT,
    tags TEXT[] DEFAULT '{}',
    metadata JSONB DEFAULT '{}',
    based_on JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    refresh_trigger TEXT DEFAULT 'manual'
);

CREATE INDEX idx_mental_models_bank_id ON mental_models(bank_id);
CREATE INDEX idx_mental_models_tags ON mental_models USING GIN(tags);

-- Reasoning chains (new, for Epic 3)
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

### Modified Tables

```sql
-- banks table: add tags column for bank selection
ALTER TABLE banks ADD COLUMN IF NOT EXISTS tags TEXT[] DEFAULT '{}';
CREATE INDEX IF NOT EXISTS idx_banks_tags ON banks USING GIN(tags);
```

### New Pydantic Models

```python
# In response_models.py or new cross_bank_models.py

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

class MentalModelReference(BaseModel):
    """Reference to a mental model used in reasoning."""
    id: str
    name: str
    bank_id: str
    excerpt: str  # Relevant portion of the mental model

class CrossBankRecallResult(BaseModel):
    """Result from cross-bank recall."""
    results: list[CrossBankFact]
    bank_stats: dict[str, int]
    total_results: int

class CrossBankReflectResult(BaseModel):
    """Result from cross-bank reflect."""
    text: str
    based_on: list[CrossBankFact]
    mental_models_used: list[MentalModelReference]
    bank_dispositions: dict[str, dict]  # bank_id -> disposition dict
    structured_output: dict | None = None
    reasoning_chain: list[dict] | None = None  # If multi-step was used
    new_opinions: list[dict] = []

class ReasoningStepModel(BaseModel):
    """A single step in a reasoning chain."""
    step_number: int
    question: str
    relevant_banks: list[str]
    conclusion: str
    confidence: float
    evidence_count: int
    budget_used: int
```

---

## 6. API Surface Changes

### New HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/default/cross-bank/recall` | Cross-bank recall with fusion |
| POST | `/v1/default/cross-bank/reflect` | Cross-bank reflect with synthesis |
| GET | `/v1/default/banks/{bank_id}/mental-models` | List mental models |
| GET | `/v1/default/banks/{bank_id}/mental-models/{id}` | Get mental model |
| POST | `/v1/default/banks/{bank_id}/mental-models` | Create mental model |
| PUT | `/v1/default/banks/{bank_id}/mental-models/{id}` | Update mental model |
| DELETE | `/v1/default/banks/{bank_id}/mental-models/{id}` | Delete mental model |
| POST | `/v1/default/banks/{bank_id}/mental-models/{id}/refresh` | Refresh mental model |

### New MCP Tools

| Tool | Epic | Description |
|------|------|-------------|
| `cross_bank_recall` | 2 | Search across multiple banks |
| `cross_bank_reflect` | 2 | Reflect across multiple banks |
| `create_documents` | 2 | Retain text documents as named document group (MCP analogue of `/files/retain`) |
| `list_mental_models` | 1 | List mental models in a bank |
| `get_mental_model` | 1 | Get a specific mental model |
| `create_mental_model` | 1 | Create a new mental model |
| `update_mental_model` | 1 | Update a mental model |
| `delete_mental_model` | 1 | Delete a mental model |
| `refresh_mental_model` | 1 | Refresh mental model content |

### Modified Endpoints

| Endpoint | Change |
|----------|--------|
| `POST /reflect` | Add `include_reasoning_chain` param, multi-step for MID/HIGH budget |
| `POST /reflect` (MCP) | Add `response_schema`, `include_reasoning_chain` params |

---

## 7. Extension Hook Design

### New Hooks for Cross-Bank Operations

```python
# In operation_validator.py

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

# New methods on OperationValidatorExtension:
async def validate_cross_bank_recall(self, ctx: CrossBankRecallContext) -> ValidationResult
async def on_cross_bank_recall_complete(self, result: CrossBankRecallResult) -> None
async def validate_cross_bank_reflect(self, ctx: CrossBankReflectContext) -> ValidationResult
async def on_cross_bank_reflect_complete(self, result: CrossBankReflectResult) -> None
```

### Billing Model for Cross-Bank

Each bank involved in a cross-bank operation triggers its own bank-level hooks **in addition to** the cross-bank hooks:

```
cross_bank_reflect(bank_ids=["A", "B"])
  → validate_cross_bank_reflect (pre, once)
  → validate_recall for Bank A (pre, per-bank)
  → validate_recall for Bank B (pre, per-bank)
  → [execution]
  → on_recall_complete for Bank A (post, per-bank)
  → on_recall_complete for Bank B (post, per-bank)
  → on_cross_bank_reflect_complete (post, once with aggregated stats)
```

This ensures per-bank billing is accurate while also providing aggregate cross-bank metrics.

---

## 8. Risk Analysis

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| ~~Merge conflicts with upstream~~ | ~~Medium~~ | ~~High~~ | RESOLVED — Epic 0 complete, 1 conflict resolved (mcp.py → accepted upstream) |
| Cross-bank latency exceeds 10s | High | Medium | Parallel execution; budget limits; early termination for empty banks |
| Schema isolation breach | Critical | Low | No cross-schema SQL; all cross-bank via Python orchestration layer |
| Disposition reconciliation artifacts | Low | Medium | Log reconciliation decisions; provide `disposition_strategy` param |
| Mental model conflicts across banks | Medium | Medium | Return both with attribution; let caller resolve |
| Budget exhaustion in step 1 of multi-step | High | Medium | Reserve 30% for synthesis; hard budget caps per step |
| Extension hook overhead for cross-bank | Low | Low | Batch hooks where possible; async post-hooks |
| Reasoning decomposition quality | Medium | Medium | Fall back to single-step if decomposition fails; validate sub-questions |

### Migration Path

0. **Phase 0 (Epic 0):** COMPLETE — Fork synced with upstream v0.4.15.
1. **Phase 1 (Epic 1):** COMPLETE — Mental models + 28 MCP tools arrived via Epic 0 merge.
2. **Phase 2 (Epic 2):** NEXT — Add cross-bank endpoints + `create_documents` tool. New endpoints only. Existing endpoints unchanged.
3. **Phase 3 (Epic 3):** Add multi-step to reflect. LOW budget unchanged. MID/HIGH gain new behavior (opt-in via `include_reasoning_chain`).
4. **Phase 4 (Epic 4):** DEFERRED — Bouncer requires review mechanism that doesn't exist yet.
5. **Phase 5 (Epic 5):** Nudges — Claude Code skill calling cross_bank_reflect on schedule.
6. **Phase 6 (Epic 6):** Fix button — correction API + cascading mental model refresh.

Epics 0-1 are complete. Epic 2 is next. Epics 3, 5, 6 are independent of each other (all depend on Epic 2). Epic 4 is deferred.

---

## Appendix A: File Inventory

| New File | Epic | Purpose |
|----------|------|---------|
| `engine/cross_bank.py` | 2 | CrossBankOrchestrator |
| `engine/reasoning.py` | 3 | ReasoningEngine |
| `engine/budget.py` | 2, 3 | BudgetAllocator, ReasoningBudgetManager |
| `api/cross_bank_models.py` | 2 | Pydantic models for cross-bank operations |
| `alembic/versions/xxx_mental_models.py` | 1 | Mental models migration |
| `alembic/versions/xxx_cross_bank.py` | 2, 3 | Banks tags + reasoning chains |
| `tests/test_cross_bank.py` | 2 | Cross-bank integration tests |
| `tests/test_reasoning.py` | 3 | Multi-step reasoning tests |
| `tests/test_mental_models.py` | 1 | Mental model tests (from upstream) |

| Modified File | Epic | Changes |
|---------------|------|---------|
| `engine/memory_engine.py` | 1, 2, 3 | Mental model methods, reasoning engine init |
| `api/http.py` | 1, 2 | Mental model + cross-bank endpoints |
| `api/mcp.py` | 1, 2 | Mental model + cross-bank MCP tools |
| `api/mcp_tools.py` | 1 | 18 new MCP tools (from upstream) |
| `extensions/operation_validator.py` | 1, 2 | Mental model + cross-bank hooks |
| `extensions/__init__.py` | 1, 2 | Export new types |
| `engine/search/think_utils.py` | 1, 3 | Hierarchical retrieval, multi-step |

---

## Appendix B: Nate B Jones Architecture Mapping

This table maps Jones' eight building blocks to specific Hindsight components:

| Building Block | Hindsight Component | Epic | Implementation Notes |
|---------------|-------------------|------|---------------------|
| Dropbox | `retain()` MCP tool | Existing | Frictionless capture via MCP — any client can retain |
| Sorter | Fact extraction pipeline (`engine/retain/fact_extraction.py`) | Existing | LLM classifies into fact types + entity extraction |
| Form | Pydantic models + fact type schemas | Existing | Structured via `world`/`experience`/`opinion` types |
| Filing Cabinet | Banks + PostgreSQL + pgvector | Existing | Per-bank schema isolation |
| Receipt | `OperationValidatorExtension` hooks | Existing | Pre/post operation audit trail |
| Bouncer | Confidence-gated retain (extension hook) | Epic 4 | Use `validate_retain()` to reject low-confidence items |
| Tap on Shoulder | Skill-driven scheduled cross-bank reflect | Epic 5 | Claude Code skill → `cross_bank_reflect()` → output |
| Fix Button | Correction API + cascading refresh | Epic 6 | `correct_memory()` → update/delete → re-consolidate mental models |

---

## 9. Epic 4-6: Second Brain Building Blocks

### Epic 4: Bouncer (Confidence-Gated Retain) — DEFERRED

**Status:** DEFERRED — No user review mechanism exists. See PRD Appendix C for full rationale.

**Technical foundation preserved:** The `OperationValidatorExtension.validate_retain()` hook remains the correct injection point. The confidence scoring approach (fact extraction quality, entity coherence, content substance) is valid. When a review mechanism is built (control plane UI, review skill, or inline clarification flow), this epic can be promoted with minimal new design work.

**Recommended future approach:** Inline clarification via `validate_retain()` rejection messages (matches Jones' bouncer pattern of asking for clarification rather than silently queuing).

### Epic 5: Nudges (Skill-Driven Scheduled Reflect)

**No changes to Hindsight core.** This is a Claude Code skill that calls existing MCP tools.

**Skill file:** `.claude/skills/second-brain-nudge/SKILL.md`

The skill uses:
- `cross_bank_reflect(query, bank_ids, budget, response_schema)` — already built in Epic 2
- Structured output via `response_schema` — already built in Epic 1
- `/loop` skill for scheduling — already exists in Claude Code

**Daily digest prompt:**
```
Reflect across all my banks. What are my top 3 actions for today?
What open loops need attention? What small win can I celebrate?
Keep it under 150 words. Be specific and actionable.
```

**Weekly review prompt:**
```
Reflect across all my banks with HIGH budget. What happened this week?
What are the biggest stalled items? What patterns are emerging?
Suggest 3 actions for next week. Identify one recurring theme.
Keep it under 250 words.
```

### Epic 6: Fix Button (Correction Feedback Loop)

**New endpoint + MCP tool + cascading mental model refresh.**

```python
# New HTTP endpoint
@app.post("/v1/default/banks/{bank_id}/memories/{memory_id}/correct")
async def correct_memory(
    bank_id: str,
    memory_id: str,
    request: CorrectionRequest,
    request_context: RequestContext = Depends(get_request_context),
):
    """Correct a memory and cascade updates to affected mental models."""

    # 1. Apply correction
    if request.action == "delete":
        await engine.delete_memory(bank_id, memory_id)
    elif request.action == "update":
        await engine.update_memory_text(bank_id, memory_id, request.corrected_text)
    elif request.action == "reclassify":
        await engine.reclassify_memory(bank_id, memory_id, request.corrected_fact_type)

    # 2. Log correction in audit trail
    await engine.log_correction(bank_id, memory_id, request)

    # 3. Find affected mental models (via based_on tracking)
    affected_models = await engine.find_mental_models_using_fact(bank_id, memory_id)

    # 4. Refresh affected mental models (re-run source_query)
    for model in affected_models:
        await engine.submit_async_refresh_mental_model(bank_id, model.id)

    return CorrectionResponse(
        corrected=True,
        affected_mental_models=[m.id for m in affected_models],
        refresh_triggered=len(affected_models),
    )
```

**MCP tool:**
```python
@mcp_tool
async def correct_memory(
    memory_id: str,
    action: str,  # "update" | "delete" | "reclassify"
    corrected_text: str | None = None,
    corrected_fact_type: str | None = None,
    reason: str | None = None,
    bank_id: str | None = None,
) -> str:
    """Correct a misclassified or incorrect memory. Cascades to affected mental models."""
```

**Cascading refresh flow:**
```
correct_memory(memory_id="fact-123", action="update", corrected_text="...")
        │
        ▼
1. Update fact-123 in memory_units
2. Query mental_models WHERE based_on ? 'fact-123'
   → Found: ["model-A", "model-B"]
3. For each affected model:
   → submit_async_refresh_mental_model(model_id)
   → This re-runs model.source_query against current (corrected) facts
   → Model content regenerates with corrected evidence
4. Log correction event for audit trail
5. Return: {corrected: true, affected_mental_models: ["model-A", "model-B"]}
```
