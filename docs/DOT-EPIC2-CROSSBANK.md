# DOT Pipeline: Epic 2 — Cross-Bank Querying

**PRD:** PRD-SECONDBRAIN-001 | **SD:** SD-SECONDBRAIN-001
**Epic:** 2 — Cross-Bank Querying (MCP + SDK)
**Date:** 2026-03-15
**Depends On:** Epic 0 (COMPLETE), Epic 1 (COMPLETE)

---

## Pipeline Overview

```
Phase 1: DESIGN (data models + interfaces)
  ├─ T1: Cross-bank Pydantic models
  ├─ T2: CrossBankOrchestrator interface
  └─ T3: Extension hook contexts for cross-bank ops
           │
Phase 2: ORCHESTRATE (core engine)
  ├─ T4: BankSelector — resolve bank list
  ├─ T5: BudgetAllocator — split budget across banks
  ├─ T6: CrossBankOrchestrator.cross_bank_recall()
  ├─ T7: Reciprocal Rank Fusion for cross-bank results
  ├─ T8: Disposition reconciliation
  └─ T9: CrossBankOrchestrator.cross_bank_reflect()
           │
Phase 3: EXPOSE (API surface)
  ├─ T10: HTTP endpoints for cross-bank recall/reflect
  ├─ T11: MCP tools — cross_bank_recall, cross_bank_reflect
  ├─ T12: MCP tool — create_documents
  └─ T13: Extension hook integration (pre/post for cross-bank)
           │
Phase 4: TEST (validation)
  ├─ T14: Unit tests — models, bank selector, budget allocator
  ├─ T15: Integration tests — cross-bank recall
  ├─ T16: Integration tests — cross-bank reflect
  ├─ T17: MCP tool tests
  └─ T18: Extension hook tests
```

---

## Task Dependency Graph

```
T1 ─┬─→ T2 ─┬─→ T4 ─→ T6 ─┬─→ T7 ─→ T9 ─┬─→ T10 ─→ T14
    │       │       T5 ─┘       T8 ─┘      ├─→ T11 ─→ T15
    │       └─→ T3 ──────────────────────→ T13 ──→ T16
    │                                       ├─→ T12 ─→ T17
    └───────────────────────────────────────└──────→ T18
```

**Critical path:** T1 → T2 → T4 → T6 → T7 → T9 → T10 → T15

**Parallelizable pairs:**
- T4 + T5 (both depend on T2, independent of each other)
- T7 + T8 (both post-T6, independent)
- T10 + T11 + T12 + T13 (all exposure tasks, after T9)
- T14 + T15 + T16 + T17 + T18 (all test tasks)

---

## Phase 1: DESIGN

### T1: Cross-Bank Pydantic Models

**File:** `hindsight-api/hindsight_api/engine/cross_bank_models.py` (NEW)

**Deliverables:**
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

class MentalModelReference(BaseModel):
    """Reference to a mental model used in reasoning."""
    id: str
    name: str
    bank_id: str
    excerpt: str

class CrossBankRecallResult(BaseModel):
    """Result from cross-bank recall."""
    results: list[CrossBankFact]
    bank_stats: dict[str, int]        # facts per bank
    total_results: int
    query: str

class CrossBankReflectResult(BaseModel):
    """Result from cross-bank reflect."""
    text: str
    based_on: list[CrossBankFact]
    mental_models_used: list[MentalModelReference]
    bank_dispositions: dict[str, dict]
    structured_output: dict | None = None
    new_opinions: list[dict] = []

class BankInfo(BaseModel):
    """Resolved bank with profile."""
    bank_id: str
    name: str | None = None
    disposition: dict = {}
    mission: str = ""
    tags: list[str] = []
```

**Acceptance Criteria:**
- All models serialize/deserialize correctly
- `CrossBankFact` wraps existing `RecallResultModel` facts with bank attribution
- Models imported from `__init__.py` or `cross_bank_models.py`

**Blocked by:** None
**Estimated effort:** Small

---

### T2: CrossBankOrchestrator Interface

**File:** `hindsight-api/hindsight_api/engine/cross_bank.py` (NEW)

**Deliverables:**
- Class skeleton with constructor accepting `MemoryEngine`
- Method signatures for `cross_bank_recall()` and `cross_bank_reflect()`
- No implementation yet — just interface + docstrings

```python
class CrossBankOrchestrator:
    def __init__(self, engine: MemoryEngine):
        self.engine = engine

    async def cross_bank_recall(
        self, query: str, bank_ids: list[str] | None = None,
        bank_tags: list[str] | None = None, max_results: int = 20,
        budget: Budget = Budget.MID,
        request_context: RequestContext | None = None,
    ) -> CrossBankRecallResult: ...

    async def cross_bank_reflect(
        self, query: str, bank_ids: list[str] | None = None,
        bank_tags: list[str] | None = None, budget: Budget = Budget.MID,
        context: str | None = None, include_mental_models: bool = True,
        response_schema: dict | None = None,
        request_context: RequestContext | None = None,
    ) -> CrossBankReflectResult: ...
```

**Acceptance Criteria:**
- Class importable from `engine.cross_bank`
- Constructor works with existing `MemoryEngine` instance
- Methods raise `NotImplementedError` initially

**Blocked by:** T1
**Estimated effort:** Small

---

### T3: Extension Hook Contexts for Cross-Bank

**File:** `hindsight-api/hindsight_api/extensions/operation_validator.py` (MODIFY)

**Deliverables:**
Add new dataclasses and abstract methods:
```python
@dataclass
class CrossBankRecallContext:
    bank_ids: list[str]
    query: str
    budget: Budget
    request_context: RequestContext

@dataclass
class CrossBankRecallResult:
    bank_ids: list[str]
    query: str
    results_per_bank: dict[str, int]
    total_results: int
    request_context: RequestContext
    success: bool = True
    error: str | None = None

@dataclass
class CrossBankReflectContext:
    bank_ids: list[str]
    query: str
    budget: Budget
    include_mental_models: bool
    request_context: RequestContext

@dataclass
class CrossBankReflectResultContext:
    bank_ids: list[str]
    query: str
    facts_per_bank: dict[str, int]
    mental_models_per_bank: dict[str, int]
    output_tokens: int
    request_context: RequestContext
    success: bool = True
    error: str | None = None
```

New abstract methods on `OperationValidatorExtension`:
```python
async def validate_cross_bank_recall(self, ctx) -> ValidationResult:
    return ValidationResult.accept()  # Default: allow

async def validate_cross_bank_reflect(self, ctx) -> ValidationResult:
    return ValidationResult.accept()  # Default: allow

async def on_cross_bank_recall_complete(self, result) -> None:
    pass  # Default: no-op

async def on_cross_bank_reflect_complete(self, result) -> None:
    pass  # Default: no-op
```

**Acceptance Criteria:**
- New contexts and methods are backward-compatible (default implementations)
- Existing extensions don't need to change
- New types exported from `extensions/__init__.py`

**Blocked by:** T2
**Estimated effort:** Small

---

## Phase 2: ORCHESTRATE

### T4: BankSelector — Resolve Bank List

**File:** `hindsight-api/hindsight_api/engine/cross_bank.py` (MODIFY)

**Deliverables:**
```python
class BankSelector:
    """Resolves which banks participate in a cross-bank query."""

    def __init__(self, engine: MemoryEngine):
        self.engine = engine

    async def resolve(
        self, bank_ids: list[str] | None = None,
        bank_tags: list[str] | None = None,
        request_context: RequestContext | None = None,
    ) -> list[BankInfo]:
        """Resolve bank list from explicit IDs, tags, or all accessible."""
```

**Logic:**
1. If `bank_ids` provided → validate each exists via `engine.get_bank_profile()`, return
2. If `bank_tags` provided → `engine.list_banks()` → filter by tags
3. If neither → `engine.list_banks()` → return all
4. For each bank, load profile (name, disposition, mission)
5. Raise `ValueError` if no banks resolved

**Acceptance Criteria:**
- Explicit bank_ids are validated (error if bank doesn't exist)
- Tag-based filtering works against `banks.tags` column
- Empty result raises descriptive error
- Bank profiles loaded for all resolved banks

**Blocked by:** T2
**Estimated effort:** Medium

---

### T5: BudgetAllocator — Split Budget Across Banks

**File:** `hindsight-api/hindsight_api/engine/cross_bank.py` (MODIFY)

**Deliverables:**
```python
class BudgetAllocator:
    """Allocates query budget across banks."""

    @staticmethod
    def equal_split(budget: Budget, n_banks: int) -> dict[str, Budget]:
        """Split budget equally. Each bank gets budget/n mapped to nearest Budget enum."""

    @staticmethod
    def proportional(budget: Budget, bank_sizes: dict[str, int]) -> dict[str, Budget]:
        """Allocate proportional to bank memory count."""
```

**Budget mapping logic:**
- Total budget value / n_banks → map to nearest Budget enum
- E.g., HIGH(600) / 3 banks = 200 per bank → map to MID(300) since it's closest above
- Conservative: round up to ensure each bank has adequate budget

**Acceptance Criteria:**
- Equal split distributes budget fairly
- No bank gets less than LOW budget
- Budget enum mapping is deterministic

**Blocked by:** T2
**Estimated effort:** Small

---

### T6: CrossBankOrchestrator.cross_bank_recall()

**File:** `hindsight-api/hindsight_api/engine/cross_bank.py` (MODIFY)

**Deliverables:**
Implement the core recall algorithm:

```python
async def cross_bank_recall(self, ...) -> CrossBankRecallResult:
    # 1. Resolve banks
    banks = await self.bank_selector.resolve(bank_ids, bank_tags, request_context)

    # 2. Allocate budget
    budgets = BudgetAllocator.equal_split(budget, len(banks))

    # 3. Parallel recall across banks
    tasks = [
        self.engine.recall_async(
            bank_id=bank.bank_id, query=query, budget=bank_budget,
            request_context=request_context,
        )
        for bank, bank_budget in zip(banks, budgets.values())
    ]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    # 4. Fuse results (RRF — delegated to T7)
    fused = self._reciprocal_rank_fusion(per_bank_results)

    # 5. Build CrossBankRecallResult
    return CrossBankRecallResult(...)
```

**Key implementation notes:**
- Use `asyncio.gather` with `return_exceptions=True` for fault tolerance
- Failed banks logged as warnings, not hard errors
- Each result tagged with `bank_id` for attribution
- Per-bank validator hooks fire within `recall_async` (existing mechanism)

**Acceptance Criteria:**
- Parallel bank queries execute concurrently
- Failed bank doesn't block other banks
- Results include bank attribution on every fact
- `bank_stats` accurately counts facts per bank

**Blocked by:** T4, T5
**Estimated effort:** Large

---

### T7: Reciprocal Rank Fusion

**File:** `hindsight-api/hindsight_api/engine/cross_bank.py` (MODIFY)

**Deliverables:**
```python
def _reciprocal_rank_fusion(
    self,
    per_bank_results: dict[str, RecallResultModel],
    k: int = 60,
    max_results: int = 20,
) -> list[CrossBankFact]:
    """Fuse ranked results from multiple banks using RRF.

    RRF score = Σ 1/(k + rank_i) across all lists containing this fact.
    k=60 is the standard constant.
    """
```

**Algorithm:**
1. For each bank's result list, assign rank positions (1-indexed)
2. For each fact, accumulate RRF score: `1 / (k + rank_in_this_bank)`
3. If same entity appears in multiple banks, merge (keep highest-scored version, attribute to originating bank)
4. Sort by accumulated RRF score descending
5. Return top `max_results`

**Entity deduplication:**
- Match by entity ID if available
- Fallback: match by text similarity (cosine > 0.95 → same fact)
- Deduped facts list all source banks in metadata

**Acceptance Criteria:**
- Facts appearing in multiple banks get boosted (higher RRF score)
- Deduplication prevents redundant results
- Bank attribution preserved on every fact
- `max_results` respected

**Blocked by:** T6
**Estimated effort:** Medium

---

### T8: Disposition Reconciliation

**File:** `hindsight-api/hindsight_api/engine/cross_bank.py` (MODIFY)

**Deliverables:**
```python
def _reconcile_dispositions(
    self,
    bank_results: dict[str, list[CrossBankFact]],
    bank_dispositions: dict[str, DispositionTraits],
) -> DispositionTraits:
    """Weight each bank's disposition by how many relevant facts it contributed."""
```

**Algorithm:**
- Count facts contributed per bank
- Weight each bank's disposition proportionally
- Return weighted average: `Σ (bank_weight × bank_disposition) / Σ weights`
- If all banks contribute 0 facts, return default disposition (3/3/3)

**Acceptance Criteria:**
- Bank contributing more facts has more influence on final disposition
- Default disposition returned when no facts
- All three traits (skepticism, literalism, empathy) stay in 1-5 range

**Blocked by:** T6
**Estimated effort:** Small

---

### T9: CrossBankOrchestrator.cross_bank_reflect()

**File:** `hindsight-api/hindsight_api/engine/cross_bank.py` (MODIFY)

**Deliverables:**
Implement cross-bank reflect, building on recall + disposition reconciliation:

```python
async def cross_bank_reflect(self, ...) -> CrossBankReflectResult:
    # 1. Resolve banks
    banks = await self.bank_selector.resolve(bank_ids, bank_tags, request_context)

    # 2. Gather evidence (parallel per bank)
    evidence_tasks = []
    for bank in banks:
        evidence_tasks.append(self._gather_bank_evidence(bank, query, budget, request_context))
    evidence = await asyncio.gather(*evidence_tasks, return_exceptions=True)

    # 3. Fuse facts via RRF
    fused_facts = self._reciprocal_rank_fusion(per_bank_recalls)

    # 4. Collect mental models from all banks
    mental_models = self._collect_mental_models(per_bank_evidence)

    # 5. Reconcile dispositions
    disposition = self._reconcile_dispositions(bank_results, bank_dispositions)

    # 6. Synthesize (single LLM call)
    #    System prompt: aggregated disposition + all bank backgrounds
    #    User prompt: fused facts + mental models + query
    synthesis = await self._synthesize(query, fused_facts, mental_models, disposition, context, response_schema)

    # 7. Build result
    return CrossBankReflectResult(...)
```

**_gather_bank_evidence** collects per bank:
- `recall_async()` results (facts)
- `search_mental_models()` if `include_mental_models`
- Bank profile (disposition, background, mission)

**_synthesize** builds the LLM prompt:
- System prompt includes reconciled disposition description
- Each bank's background and mission included with attribution
- Facts attributed with `[Bank: X]` markers
- Mental models included with `[Bank: X]` markers
- Uses existing LLM infrastructure from reflect pipeline

**Acceptance Criteria:**
- Cross-bank reflect returns coherent synthesis drawing on multiple banks
- Mental models from all banks included when `include_mental_models=True`
- `response_schema` produces structured output
- `based_on` field correctly attributes facts to source banks
- Bank dispositions influence the synthesis tone

**Blocked by:** T7, T8
**Estimated effort:** Large

---

## Phase 3: EXPOSE

### T10: HTTP Endpoints for Cross-Bank

**File:** `hindsight-api/hindsight_api/api/http.py` (MODIFY)

**Deliverables:**
```python
# New request/response models
class CrossBankRecallRequest(BaseModel):
    query: str
    bank_ids: list[str] | None = None
    bank_tags: list[str] | None = None
    max_results: int = 20
    budget: str = "mid"

class CrossBankReflectRequest(BaseModel):
    query: str
    bank_ids: list[str] | None = None
    bank_tags: list[str] | None = None
    budget: str = "mid"
    context: str | None = None
    include_mental_models: bool = True
    response_schema: dict | None = None

# New endpoints
@app.post("/v1/default/cross-bank/recall")
async def api_cross_bank_recall(request: CrossBankRecallRequest, ...) -> CrossBankRecallResult

@app.post("/v1/default/cross-bank/reflect")
async def api_cross_bank_reflect(request: CrossBankReflectRequest, ...) -> CrossBankReflectResult
```

**Implementation notes:**
- Endpoints create `CrossBankOrchestrator` from `app.state.memory`
- Budget string mapped to `Budget` enum (same pattern as existing reflect endpoint)
- `request_context` propagated from `Depends(get_request_context)`
- Tag `["Cross-Bank"]` in OpenAPI docs

**Acceptance Criteria:**
- Both endpoints accessible at documented paths
- Request validation rejects invalid budget strings
- Response matches `CrossBankRecallResult`/`CrossBankReflectResult` models
- Auth/tenant propagation works (via `get_request_context`)

**Blocked by:** T9
**Estimated effort:** Medium

---

### T11: MCP Tools — cross_bank_recall, cross_bank_reflect

**File:** `hindsight-api/hindsight_api/mcp_tools.py` (MODIFY)

**Deliverables:**
Add two new tool registration functions following existing pattern:

```python
def _register_cross_bank_recall(mcp, memory, config):
    # Only in multi-bank mode
    if not config.include_bank_id_param:
        return

    @mcp.tool()
    async def cross_bank_recall(
        query: str, bank_ids: list[str] | None = None,
        bank_tags: list[str] | None = None,
        max_results: int = 20, budget: str = "mid",
    ) -> str:
        """Search memories across multiple banks with fused ranking."""
        ...

def _register_cross_bank_reflect(mcp, memory, config):
    # Only in multi-bank mode
    if not config.include_bank_id_param:
        return

    @mcp.tool()
    async def cross_bank_reflect(
        query: str, bank_ids: list[str] | None = None,
        bank_tags: list[str] | None = None,
        budget: str = "mid", context: str | None = None,
        include_mental_models: bool = True,
        response_schema: dict | None = None,
    ) -> str:
        """Reflect across multiple banks with disposition-aware synthesis."""
        ...
```

**Implementation notes:**
- Only registered when `include_bank_id_param=True` (multi-bank mode)
- NOT available in single-bank mode (`/mcp/{bank_id}/`)
- Returns JSON strings (matching existing tool pattern)
- Add to `_ALL_TOOLS` set in `mcp.py`
- Add to `register_mcp_tools()` dispatch

**Acceptance Criteria:**
- Tools appear in multi-bank MCP server
- Tools do NOT appear in single-bank MCP server
- JSON output includes bank attribution
- `bank_ids=None` queries all accessible banks

**Blocked by:** T9
**Estimated effort:** Medium

---

### T12: MCP Tool — create_documents

**File:** `hindsight-api/hindsight_api/mcp_tools.py` (MODIFY)

**Deliverables:**
```python
def _register_create_documents(mcp, memory, config):
    @mcp.tool()
    async def create_documents(
        contents: list[dict],
        document_name: str | None = None,
        tags: list[str] | None = None,
        bank_id: str | None = None,
    ) -> str:
        """Retain one or multiple text documents as a named document group.

        Analogous to HTTP /files/retain but for MCP text content.
        Creates a document record, extracts facts, builds knowledge graph.

        Args:
            contents: List of items, each with:
                - content (str): Document text
                - context (str): Category (e.g., 'meeting-notes', 'research')
                - tags (list[str], optional): Per-item tags
                - metadata (dict, optional): Per-item metadata
            document_name: Human-readable name for the document group
            tags: Tags applied to the entire document
            bank_id: Target bank (defaults to session bank)
        """
        target_bank = bank_id or config.bank_id_resolver()
        if not target_bank:
            return json.dumps({"error": "No bank_id configured"})

        # Generate document_id, attach to each content item
        document_id = str(uuid.uuid4())
        retain_contents = []
        for item in contents:
            content_dict, err = build_content_dict(
                content=item["content"],
                context=item.get("context", "general"),
                tags=item.get("tags"),
                metadata=item.get("metadata"),
                document_id=document_id,
            )
            if err:
                return json.dumps({"error": err})
            retain_contents.append(content_dict)

        result = await memory.submit_async_retain(
            bank_id=target_bank,
            contents=retain_contents,
            request_context=_get_request_context(config),
            document_tags=tags,
        )

        return json.dumps({
            "success": True,
            "document_id": document_id,
            "document_name": document_name,
            "items_count": len(contents),
            "bank_id": target_bank,
            "operation_id": result.get("operation_id"),
        })
```

**Implementation notes:**
- Reuses existing `submit_async_retain` with `document_id`
- Each content item becomes a separate memory unit grouped by document_id
- `document_name` stored via document metadata (if supported) or ignored initially
- Available in both single-bank and multi-bank modes

**Acceptance Criteria:**
- Tool creates a document group with unique document_id
- All content items linked to same document
- Facts extracted from each content item
- Operation ID returned for async tracking
- Tags propagated to document and content items

**Blocked by:** T1 (needs models, but independent of cross-bank)
**Estimated effort:** Medium

---

### T13: Extension Hook Integration

**File:** `hindsight-api/hindsight_api/engine/cross_bank.py` (MODIFY)

**Deliverables:**
Wire cross-bank validator hooks into orchestrator:

```python
# In CrossBankOrchestrator.cross_bank_recall():
if self.engine._operation_validator:
    ctx = CrossBankRecallContext(bank_ids=resolved_bank_ids, query=query, ...)
    await self.engine._validate_operation(
        self.engine._operation_validator.validate_cross_bank_recall(ctx)
    )

# After execution:
if self.engine._operation_validator:
    result_ctx = CrossBankRecallResult(
        bank_ids=resolved_bank_ids, results_per_bank=stats, ...
    )
    try:
        await self.engine._operation_validator.on_cross_bank_recall_complete(result_ctx)
    except Exception as e:
        logger.warning(f"Post-hook error: {e}")
```

Same pattern for `cross_bank_reflect`.

**Billing model:**
- Cross-bank pre/post hooks fire ONCE per cross-bank operation
- Per-bank pre/post hooks fire via existing `recall_async`/`reflect_async` (already handled)
- This gives: 1 cross-bank hook + N per-bank hooks per operation

**Acceptance Criteria:**
- Pre-hooks can reject cross-bank operations
- Post-hooks receive accurate per-bank stats
- Per-bank hooks still fire (existing behavior preserved)
- Post-hook errors are non-fatal (logged as warnings)

**Blocked by:** T3, T9
**Estimated effort:** Medium

---

## Phase 4: TEST

### T14: Unit Tests — Models, BankSelector, BudgetAllocator

**File:** `hindsight-api/tests/test_cross_bank_unit.py` (NEW)

**Test cases:**
- `test_cross_bank_fact_serialization` — model round-trip
- `test_cross_bank_recall_result_bank_stats` — stats computation
- `test_bank_selector_explicit_ids` — validates and returns requested banks
- `test_bank_selector_empty_raises` — error on no banks resolved
- `test_budget_equal_split_2_banks` — correct budget per bank
- `test_budget_equal_split_5_banks` — no bank below LOW
- `test_rrf_single_bank` — degenerate case = original ranking
- `test_rrf_two_banks_overlap` — shared facts get boosted
- `test_disposition_reconciliation_equal_weight` — average of two equal banks
- `test_disposition_reconciliation_skewed` — heavier bank dominates

**Blocked by:** T1-T8
**Estimated effort:** Medium

---

### T15: Integration Tests — Cross-Bank Recall

**File:** `hindsight-api/tests/test_cross_bank_recall.py` (NEW)

**Test cases:**
```python
@pytest.mark.asyncio
async def test_cross_bank_recall_two_banks(memory, request_context):
    # Setup: retain different facts in bank_a and bank_b
    # Act: cross_bank_recall(query, bank_ids=[bank_a, bank_b])
    # Assert: results contain facts from both banks with attribution

async def test_cross_bank_recall_bank_not_found(memory, request_context):
    # Act: cross_bank_recall(query, bank_ids=["nonexistent"])
    # Assert: raises ValueError

async def test_cross_bank_recall_single_bank_fallback(memory, request_context):
    # Act: cross_bank_recall(query, bank_ids=[bank_a])
    # Assert: equivalent to single-bank recall

async def test_cross_bank_recall_budget_split(memory, request_context):
    # Verify budget distributed across banks

async def test_cross_bank_recall_failed_bank_graceful(memory, request_context):
    # One bank fails, other returns results
    # Assert: partial results returned, error logged
```

**Blocked by:** T6, T7
**Estimated effort:** Large

---

### T16: Integration Tests — Cross-Bank Reflect

**File:** `hindsight-api/tests/test_cross_bank_reflect.py` (NEW)

**Test cases:**
```python
async def test_cross_bank_reflect_two_banks(memory, request_context):
    # Setup: retain facts in two banks
    # Act: cross_bank_reflect(query, bank_ids=[bank_a, bank_b])
    # Assert: synthesis text references facts from both banks

async def test_cross_bank_reflect_mental_models(memory, request_context):
    # Setup: create mental models in both banks
    # Act: cross_bank_reflect(query, include_mental_models=True)
    # Assert: mental_models_used lists models from both banks

async def test_cross_bank_reflect_response_schema(memory, request_context):
    # Act: cross_bank_reflect(query, response_schema={...})
    # Assert: structured_output matches schema

async def test_cross_bank_reflect_disposition_influence(memory, request_context):
    # Setup: bank_a has high skepticism, bank_b has high empathy
    # Act: cross_bank_reflect(query, bank_ids=[bank_a, bank_b])
    # Assert: reconciled disposition is weighted average
```

**Blocked by:** T9
**Estimated effort:** Large

---

### T17: MCP Tool Tests

**File:** `hindsight-api/tests/test_cross_bank_mcp.py` (NEW)

**Test cases:**
```python
async def test_cross_bank_recall_mcp_tool(memory):
    # Setup: register tools, retain in two banks
    # Act: call cross_bank_recall tool via MCP
    # Assert: JSON response with bank attribution

async def test_cross_bank_reflect_mcp_tool(memory):
    # Similar for reflect

async def test_create_documents_mcp_tool(memory):
    # Act: call create_documents with 3 content items
    # Assert: document_id returned, all items linked

async def test_cross_bank_tools_not_in_single_bank_mode(memory):
    # Assert: cross_bank tools not registered when include_bank_id_param=False
```

**Blocked by:** T11, T12
**Estimated effort:** Medium

---

### T18: Extension Hook Tests

**File:** `hindsight-api/tests/test_cross_bank_hooks.py` (NEW)

**Test cases:**
```python
async def test_cross_bank_recall_pre_hook_reject(memory, request_context):
    # Setup: validator that rejects cross-bank recall
    # Act: cross_bank_recall(...)
    # Assert: OperationValidationError raised

async def test_cross_bank_reflect_post_hook_fires(memory, request_context):
    # Setup: validator that records post-hook calls
    # Act: cross_bank_reflect(...)
    # Assert: on_cross_bank_reflect_complete called with correct stats

async def test_per_bank_hooks_still_fire(memory, request_context):
    # Setup: validator that counts per-bank recall hooks
    # Act: cross_bank_recall(bank_ids=[a, b])
    # Assert: validate_recall called twice (once per bank)
```

**Blocked by:** T13
**Estimated effort:** Medium

---

## Implementation Order (Recommended Sprint Plan)

### Sprint 1: Foundation (T1-T5)
- T1: Cross-bank models — 1 session
- T2: Orchestrator interface — 1 session
- T3: Extension hook contexts — 1 session
- T4 + T5 (parallel): BankSelector + BudgetAllocator — 1 session

### Sprint 2: Core Engine (T6-T9)
- T6: cross_bank_recall implementation — 1-2 sessions
- T7 + T8 (parallel): RRF + Disposition reconciliation — 1 session
- T9: cross_bank_reflect implementation — 2 sessions

### Sprint 3: API Surface (T10-T13)
- T10 + T11 + T12 + T13 (parallel): HTTP + MCP + hooks — 2 sessions

### Sprint 4: Testing (T14-T18)
- T14: Unit tests — 1 session
- T15 + T16 + T17 + T18 (parallel): Integration + MCP + hook tests — 2 sessions

**Total estimated effort:** ~10-12 sessions

---

## File Inventory

| File | Action | Tasks |
|------|--------|-------|
| `engine/cross_bank_models.py` | NEW | T1 |
| `engine/cross_bank.py` | NEW | T2, T4, T5, T6, T7, T8, T9, T13 |
| `extensions/operation_validator.py` | MODIFY | T3 |
| `extensions/__init__.py` | MODIFY | T3 |
| `api/http.py` | MODIFY | T10 |
| `mcp_tools.py` | MODIFY | T11, T12 |
| `api/mcp.py` | MODIFY | T11 (add to _ALL_TOOLS) |
| `tests/test_cross_bank_unit.py` | NEW | T14 |
| `tests/test_cross_bank_recall.py` | NEW | T15 |
| `tests/test_cross_bank_reflect.py` | NEW | T16 |
| `tests/test_cross_bank_mcp.py` | NEW | T17 |
| `tests/test_cross_bank_hooks.py` | NEW | T18 |

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Cross-bank latency exceeds 10s | `asyncio.gather` for parallel bank queries; budget limits prevent runaway |
| Schema isolation breach | All cross-bank via Python orchestration — no cross-schema SQL |
| LLM synthesis quality | System prompt explicitly describes multi-bank context; test with real data |
| RRF deduplication false positives | Use high similarity threshold (0.95); fallback to ID-based dedup |
| Extension hook overhead | Post-hooks are async and non-fatal; pre-hooks short-circuit early |
| torch dependency blocks tests | Use mocked MemoryEngine for unit tests; integration tests need env setup |
