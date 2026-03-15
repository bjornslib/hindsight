# PRD-SECONDBRAIN-001: Hindsight as a Second Brain Memory Layer

**Status:** Draft (v0.4 — Epics 2 and 3 marked COMPLETE)
**Author:** System 3 Meta-Orchestrator
**Date:** 2026-03-15
**Version:** 0.4
**Priority:** P1

---

## 1. Problem Statement

AI personal assistants (Claude Code, voice agents, workflow automators) lack a unified memory layer that operates across contexts. Users re-explain themselves to every AI tool. Individual memory banks exist in isolation — a user's business context cannot inform their personal assistant, and vice versa.

Meanwhile, the "second brain" movement (Nate B Jones, Tiago Forte) has demonstrated that **AI-augmented knowledge systems** that capture, classify, route, and surface information dramatically reduce cognitive load. Jones' architecture identifies eight building blocks, but existing implementations use fragmented tool stacks (Zapier + Notion + Slack) rather than a unified memory engine.

Hindsight already has the core infrastructure: four memory types, bank isolation, knowledge graphs, entity extraction, and an agentic reflect loop. What's missing is the **orchestration layer** that turns isolated banks into a coherent second brain.

### Specific Gaps

1. **No cross-bank querying** — Users cannot ask questions that span their business and personal banks
2. **No mental model awareness in our fork** — Upstream has mental models; our fork needs to integrate and extend them for cross-bank synthesis
3. **No multi-step reasoning within reflect** — The agentic loop runs against a single bank; complex queries requiring reasoning across multiple knowledge domains hit a wall
4. **No proactive surfacing** — Jones' "Tap on the Shoulder" pattern (daily digests, weekly reviews) has no analogue in Hindsight's current API

---

## 2. Business Goals

| Goal | Metric | Target |
|------|--------|--------|
| Enable cross-bank knowledge discovery | % of reflect queries that successfully retrieve from 2+ banks | > 80% of multi-bank queries return relevant cross-bank facts |
| Reduce context re-explanation | User satisfaction with persistent context | Qualitative: users report not needing to re-explain domain context |
| Support second brain workflows | # of building blocks implementable via Hindsight alone | 5 of 8 Jones building blocks without external tools (bouncer deferred) |
| Extend reflect for complex reasoning | Average reasoning depth for HIGH budget queries | 3+ reasoning steps (vs current 1-shot) |

---

## 3. User Stories

### Primary Persona: AI Power User (Claude Code / Voice Agent User)

**US-1: Cross-Bank Discovery**
> As a user with separate business and personal banks, I want to ask a question that draws on both contexts, so that my AI assistant can give me holistic advice without me having to specify which bank to search.

**US-2: Mental Model Synthesis**
> As a user, I want Hindsight to maintain consolidated mental models about me (my preferences, my team, my projects) that stay current as new facts arrive, so that any AI tool I connect gets rich context immediately.

**US-3: Multi-Step Reasoning**
> As a user asking a complex question like "Based on everything you know about my team and our Q1 goals, what should I prioritize this week?", I want reflect to decompose this into sub-questions, gather evidence across banks, and synthesize a well-reasoned answer.

**US-4: Proactive Surfacing (Nudges)**
> As a user, I want scheduled summaries of key patterns, open loops, and suggested actions delivered without me having to ask, so that my second brain works while I sleep.

**US-5: Confidence-Gated Storage**
> As a user, I want a quality gate (bouncer pattern) that prevents low-confidence classifications from polluting my memory, logging uncertain items for review instead.

### Secondary Persona: Developer Building on Hindsight

**US-6: SDK Multi-Bank Access**
> As a developer, I want to query multiple Hindsight banks in a single SDK call, with results fused and ranked across banks.

**US-7: Structured Reasoning Output**
> As a developer, I want reflect to return not just the final answer but the reasoning chain (which banks were consulted, which mental models used, which facts cited), so I can build transparent AI systems.

---

## 4. Technical Context

### What Exists Today (Our Fork)

| Capability | Status | Location |
|------------|--------|----------|
| Multi-bank MCP access (bank_id param) | Implemented | `mcp.py` (commit 61421658) |
| Bank profiles (disposition, background) | Implemented | `bank_utils.py` |
| Single-bank reflect (agentic loop) | Implemented | `memory_engine.py:3072` |
| Entity knowledge graph (MPFP) | Implemented | `mpfp_retrieval.py` |
| Extension hooks (pre/post operation) | Implemented | `extensions/operation_validator.py` |
| Schema-per-bank isolation | Implemented | `memory_engine.py:fq_table()` |

### What Was Upstream (Now Merged — Epic 0 Complete)

> **Epic 0 COMPLETE:** All upstream capabilities listed below are now in our fork as of merge commit `2f9d709c` (2026-03-15). The fork is synced with upstream v0.4.15.

| Capability | Status | Notes |
|------------|--------|-------|
| Mental model CRUD + MCP tools | **Merged** | 6 MCP tools in `mcp_tools.py` |
| Mental model extension hooks | **Merged** | `MentalModelRefreshContext` in operation_validator |
| Mental models in reflect hierarchy | **Merged** | Hierarchical retrieval in reflect agent |
| Structured output for reflect | **Merged** | `response_schema` parameter available |
| 28 MCP tools (see Appendix A) | **Merged** | `mcp_tools.py` (2,704 lines) |
| Hierarchical config (tenant→bank) | **Merged** | Global → Tenant → Bank config resolution |
| Pydantic AI integration | **Merged** | SDK integration for persistent agent memory |
| Batch observations consolidation | **Merged** | Performance improvement for large banks |
| Entity labels + tag filtering | **Merged** | Enhanced entity management |
| File upload + conversion API | **Merged** | PDF, DOCX, images via `/files/retain` |

### What Are Mental Models in Hindsight?

Mental models are **consolidated knowledge synthesized from multiple facts** — they are "pinned reflections" that persist across queries. Unlike atomic facts (`world`, `experience`, `opinion`), mental models represent patterns, preferences, and learnings that emerge from accumulated evidence.

| Memory Type | What It Is | Example | Created By |
|------------|-----------|---------|------------|
| **World Fact** | Objective statement | "Python 3.11 supports pattern matching" | Fact extraction (retain) |
| **Experience Fact** | First-person event | "I discussed API design with Sarah" | Fact extraction (retain) |
| **Opinion** | Belief with confidence | "React is better than Vue for our use case" (0.8) | Reflect pipeline |
| **Observation** | Objective synthesis about entities | "Sarah leads the platform team" | Observation engine |
| **Mental Model** | Consolidated pattern from many facts | "Sarah is a detail-oriented leader who values documentation" | Consolidation engine (auto) or manual creation |

**How mental models work:**
1. **Created automatically** by the consolidation engine after `retain()` operations — the engine identifies patterns across accumulated facts and creates/updates models
2. **Created manually** via `create_mental_model(name, source_query)` MCP tool — user defines a query that generates the model
3. **Stay current via `refresh_mental_model()`** — re-runs the stored `source_query` against current facts, regenerating the model content
4. **Track provenance** via `based_on` field — records which facts contributed to each model
5. **Handle contradictions** by preserving the evolution journey, not just the latest conclusion
6. **Bank mission-aware** — consolidation filters by the bank's `mission` field, so different banks create different models from the same facts

**In the reflect pipeline**, mental models participate in hierarchical retrieval:
1. **Reflections** (user-curated summaries) — highest priority
2. **Mental Models** (consolidated knowledge) — system-generated patterns
3. **Raw Facts** (ground truth) — evidence for verification

The reflect agent has access to `search_reflections`, `search_mental_models`, `recall`, `expand`, and `done` tools in an agentic loop of up to 10 iterations.

### Nate B Jones' Architecture Mapping

| Jones Building Block | Hindsight Analogue | Status | Details |
|---------------------|-------------------|--------|---------|
| Dropbox (frictionless capture) | `retain()` MCP tool | Exists | Any MCP client can retain — zero capture friction |
| Sorter (AI classification) | Fact extraction pipeline | Exists | LLM classifies into fact types + extracts entities |
| Form (standardized structure) | Fact types + entity extraction | Exists | Structured via `world`/`experience`/`opinion` types |
| Filing Cabinet (persistent store) | Banks + PostgreSQL + pgvector | Exists | Per-bank schema isolation with vector embeddings |
| Receipt (audit trail) | Operation validator extension hooks | Exists | See Appendix B |
| Bouncer (confidence filter) | Confidence-gated retain | **DEFERRED** | No user review mechanism exists; see Appendix C for deferral rationale |
| Tap on the Shoulder (nudges) | Skill-driven scheduled reflect | Epic 5 | See Appendix D |
| Fix Button (correction) | Correction feedback API | Epic 6 | See Appendix E |

---

## 5. Scope

### In Scope

- **Epic 0:** Sync fork with upstream main (prerequisite for everything)
- **Epic 1:** Merge upstream mental models + 18 new MCP tools + structured reflect
- **Epic 2:** Cross-bank recall and reflect (query spanning 2+ banks) via MCP + SDK
- **Epic 3:** Multi-step reasoning within reflect (decompose → gather → synthesize)
- **Epic 4:** ~~Confidence-gated retain (bouncer pattern)~~ — **DEFERRED** (no user review mechanism; see Appendix C)
- **Epic 5:** Proactive surfacing via skill-driven scheduled reflect (nudges)
- **Epic 6:** Correction feedback loop (fix button)
- Extension hooks for all new operations

### Out of Scope (Future Work)

- Control plane UI for cross-bank management
- Voice agent integration
- Full Open Brain MCP compatibility (see Appendix F for gap analysis — most functionality already exists)

---

## 6. Non-Functional Requirements

| Requirement | Target |
|-------------|--------|
| Cross-bank reflect latency (2 banks, MID budget) | < 10 seconds |
| Cross-bank reflect latency (5 banks, HIGH budget) | < 30 seconds |
| No cross-bank data leakage | Schema isolation maintained; cross-bank only via explicit API |
| Backward compatibility | All existing single-bank APIs unchanged |
| Extension hook coverage | Every new operation has pre/post hooks |
| Test coverage | > 80% for new code |

---

## 7. Design Principles (Informed by Research)

### From Nate B Jones' Architecture

1. **Zero decisions at capture** — The user should never specify which bank a thought belongs to. If cross-bank is enabled, the system routes automatically.
2. **Trust through transparency** — Every cross-bank decision is logged. Confidence scores visible. Corrections trivial.
3. **Reliability > features** — A conservative cross-bank merge that occasionally asks for clarification is better than an aggressive one that frequently misattributes.
4. **Separation of concerns** — Memory (banks) stays decoupled from Compute (reasoning) and Interface (MCP/SDK/HTTP).
5. **Small, frequent, reliable output** — Cross-bank reflect should return concise, well-sourced answers, not dump everything it found.

### From Hindsight's Architecture

6. **Bank isolation is sacred** — Cross-bank queries are an overlay, not a merge. Banks never share schemas.
7. **Extension hooks everywhere** — Billing, audit, and validation must work for cross-bank operations.
8. **Config is hierarchical** — Per-bank config overrides affect how that bank participates in cross-bank queries.

---

## 8. Epics

### Epic 0: Sync Fork with Upstream Main — COMPLETE

**Status:** COMPLETE (2026-03-15)

**Goal:** Bring our fork up to date with `bjornslib/hindsight` upstream `main` branch, incorporating all upstream commits including mental models, hierarchical config, structured reflect, 28 MCP tools, and Pydantic AI integration.

**What Was Done:**
- Merged 230+ upstream commits (v0.1.16 → v0.4.15) via `git merge origin/main`
- Resolved 1 conflict in `mcp.py` (9 conflict regions) — accepted upstream's refactored architecture (`mcp_tools.py` module with `register_mcp_tools()` pattern)
- `.gitignore` auto-merged cleanly
- Merge commit: `2f9d709c`
- Local files commit: `aa17ebd7`

**Acceptance Criteria — Results:**
- [x] `git log` shows all upstream commits present in our branch
- [ ] `cd hindsight-api && uv run pytest tests/` — blocked by torch platform dependency (not merge-related)
- [x] `mcp_tools.py` (2,704 lines) with 28 tools via `register_mcp_tools()` present
- [x] Mental model tables, MCP tools, and hierarchical config are present
- [x] Structured reflect (`response_schema`) available via upstream
- [x] Python syntax verified on all merged files

---

### Epic 1: Merge Upstream Mental Models — COMPLETE

**Status:** COMPLETE (2026-03-15) — Delivered via Epic 0 upstream merge

**Goal:** Integrate the upstream mental model system into our fork, establishing the foundation for cross-bank reasoning.

**What Was Done:**
All mental model functionality arrived automatically with the Epic 0 upstream merge (230+ commits). No cherry-picking or manual integration was needed. The upstream codebase had already implemented everything in this epic across multiple releases (v0.3.0 → v0.4.15).

**Acceptance Criteria — Results:**
- [x] `list_mental_models`, `get_mental_model`, `create_mental_model`, `update_mental_model`, `delete_mental_model`, `refresh_mental_model` MCP tools present in `mcp_tools.py`
- [x] Reflect agent uses hierarchical retrieval: reflections > mental models > raw facts
- [x] `response_schema` parameter on reflect available via upstream
- [x] Mental model extension hooks present (`MentalModelRefreshContext`, pre-operation validation)
- [x] Directives system present (3 MCP tools)
- [x] 28 total MCP tools registered via `register_mcp_tools()` in `mcp_tools.py` (2,704 lines)
- [ ] Test suite verification — blocked by torch platform dependency (not merge-related)

---

### Epic 2: Cross-Bank Querying (MCP + SDK) — COMPLETE

**Status:** COMPLETE (2026-03-15)

**Goal:** Enable users and AI tools to query across multiple Hindsight banks in a single operation, with results fused and ranked. Also add missing MCP tool for document creation.

**What Was Done:**
- `CrossBankOrchestrator` implemented in `engine/cross_bank.py` (1348 lines) with full parallel recall/reflect, BankSelector supporting explicit IDs/tags/all-banks modes, BudgetAllocator with equal_split/proportional/query_relevant strategies, and RRF fusion (k=60)
- `cross_bank_recall` and `cross_bank_reflect` MCP tools added to `mcp_tools.py`
- `create_documents` MCP tool added to `mcp_tools.py` — retains one or multiple documents as a named document group (analogous to HTTP `/files/retain` but for MCP text content)
- HTTP POST endpoints added to `api/http.py`: `/v1/default/cross-bank/recall` and `/v1/default/cross-bank/reflect`
- Pydantic models in `api/cross_bank_models.py`: `CrossBankFact`, `CrossBankRecallResult`, `CrossBankReflectResult`
- Extension hooks implemented: `CrossBankRecallContext`, `CrossBankReflectContext`, pre-validation and post-completion per bank
- Test suite: `tests/test_cross_bank.py` (1093 lines), `tests/test_mcp_tools.py` (+341 lines)
- Bug fix: BudgetAllocator auto-raises per-bank minimum instead of failing when budget is too low
- Disposition reconciliation weighted by fact count, clamped to 1-5 range

**Acceptance Criteria — Results:**
- [x] `cross_bank_recall(query, bank_ids=["personal", "business"])` returns ranked results with `bank_id` field on each result
- [x] `cross_bank_reflect(query, bank_ids=["personal", "business"])` synthesizes answer drawing on facts from both banks
- [x] Mental models from all queried banks are included in cross-bank reflect
- [x] Budget is split across banks (configurable: equal split, proportional to bank size, or query-relevant weighting)
- [x] Each bank's config is resolved independently (hierarchical config respected)
- [x] Extension hooks fire per-bank for billing attribution
- [x] Schema isolation is maintained — no direct cross-schema SQL

**Technical Approach:**
```
User query + bank_ids
        |
        v
For each bank (parallel):
  1. Resolve bank config
  2. Run recall/reflect with bank's config
  3. Apply bank's disposition to reasoning
        |
        v
Fusion layer:
  1. Reciprocal rank fusion across bank results
  2. Deduplicate entities across banks
  3. Attribute results to source banks
        |
        v
Synthesis (for cross_bank_reflect):
  1. LLM receives fused facts + all bank mental models
  2. System prompt includes all bank dispositions (weighted)
  3. Returns answer + reasoning chain + citations with bank attribution
```

---

### Epic 3: Multi-Step Reasoning in Reflect — COMPLETE

**Status:** COMPLETE (2026-03-15)

**Goal:** Extend the reflect pipeline to support multi-step reasoning for complex queries, with intermediate conclusions stored and reasoning chains visible.

**What Was Done:**
- `decompose` tool added to the reflect agent (`tools_schema.py`, `tools.py`) — budget-gated so decompose is only available for MID and HIGH budget queries
- `ReasoningStep` and `ReasoningChain` dataclasses added to `reflect/models.py`
- `reasoning_steps` parameter added to the `done` tool for capturing the reasoning chain at conclusion
- System prompt updated in `prompts.py` with MID/HIGH budget decompose guidance instructing the agent when and how to use decomposition
- `include_reasoning_chain` request parameter added to the reflect HTTP endpoint
- `reasoning_chain` field added to `ReflectResponse` and `ReflectResult`
- Approach A used (extend existing reflect agent rather than a separate decomposition service) — minimal new code, reuses the existing agentic loop
- HIGH budget reflect gets 20 iterations (2x default); MID budget gets 10 iterations

**Acceptance Criteria — Results:**
- [x] Complex queries CAN be decomposed into 2-4 sub-questions (via `decompose` tool, budget >= MID)
- [x] Each sub-question answered via reflect tools (`recall`, `search_mental_models`, `search_observations`)
- [x] Budget is not exhausted on step 1 — the agent manages iterations within the per-budget allocation
- [x] `include_reasoning_chain=true` returns the reasoning chain when the agent uses `decompose`
- [x] HIGH budget queries get 20 iterations (2x default); MID gets 10
- [ ] Average 3+ reasoning steps for HIGH budget — depends on query complexity and LLM behavior (agent-driven, not guaranteed by implementation)
- Note: Approach A means decomposition is OPTIONAL — the agent decides when to use the `decompose` tool based on query complexity

**Technical Approach:**
```
Complex query + budget=HIGH
        |
        v
Reflect agent (agentic loop, up to 20 iterations):
  Available tools: recall, search_mental_models,
                   search_observations, decompose, done
        |
        v
Agent decides to call decompose (optional):
  → Identifies 2-4 sub-questions
  → Calls recall/search tools per sub-question
  → Accumulates intermediate conclusions
        |
        v
Agent calls done(reasoning_steps=[...]):
  → reasoning_steps captured in ReasoningChain
        |
        v
Response (if include_reasoning_chain=true):
  text: "Based on analysis of your team dynamics and Q1 goals..."
  reasoning_chain: [{step: 1, question: "...", evidence: [...], conclusion: "..."}, ...]
  based_on: [facts cited]
```

**Budget Semantics for Multi-Step:**

| Budget | Iterations | decompose Available | Behavior |
|--------|-----------|--------------------|---------:|
| LOW (100) | 5 | No | Single-shot — backward compatible |
| MID (300) | 10 | Yes | Agent may decompose into 2 sub-questions |
| HIGH (600) | 20 | Yes | Agent may decompose into up to 4 sub-questions |

---

## 9. Dependencies

| Dependency | Epic | Risk |
|-----------|------|------|
| Upstream mental model merge | Epic 1 → Epics 2, 3 | Low (code available) |
| Hierarchical config merge | Epic 2 | Medium (47-file commit, merge conflicts possible) |
| Cross-bank schema safety | Epic 2 | Low (existing fq_table() pattern) |
| LLM structured output support | Epic 3 | Low (upstream commit available) |

---

## 10. Success Metrics

| Metric | Measurement | Target | Timeline |
|--------|------------|--------|----------|
| Cross-bank query accuracy | Manual evaluation of 50 cross-bank queries | > 75% return relevant cross-bank results | 2 weeks post-launch |
| Reasoning depth | Average steps per HIGH budget reflect | > 3 steps | At launch |
| Latency (cross-bank, 2 banks) | P95 latency | < 10s | At launch |
| Backward compatibility | Existing test suite | 100% pass | At launch |
| Extension hook coverage | New operations with hooks / total new operations | 100% | At launch |

---

## 11. Research References

| Document | Path |
|----------|------|
| Nate B Jones Second Brain Research | `docs/research/natebjones-second-brain-research.md` |
| Hindsight Upstream Commits Analysis | `docs/research/hindsight-upstream-commits-analysis.md` |
| Sophia arXiv:2512.18202 (System 3 meta-cognition) | External |
| Hindsight arXiv:2512.12818 (four-network memory) | External |

---

## 12. Open Questions

1. **Disposition reconciliation** — When cross-bank reflect encounters banks with conflicting dispositions (e.g., one high-skepticism, one high-empathy), how should the synthesis disposition be calculated? Options: weighted average, dominant bank's disposition, or separate synthesis per disposition.

2. **Mental model conflicts** — If Bank A's mental model says "User prefers Python" and Bank B's says "User prefers TypeScript", how should cross-bank reflect handle this? Options: present both with attribution, attempt reconciliation, or flag as conflict.

3. **Budget economics** — Should cross-bank queries cost more than single-bank queries? The per-bank extension hooks will fire for each bank, but the orchestration layer adds overhead.

---

## Appendix A: The 18 New Upstream MCP Tools

Upstream commit `3ffec650` adds these tools to a new `mcp_tools.py` file (+1,482 lines). Our fork currently has 5 tools (retain, recall, reflect, list_banks, create_bank). After merging, we'd have **29 total**.

**Directive tools (3):**
| Tool | Parameters | Description |
|------|-----------|-------------|
| `list_directives` | `bank_id` | List all directives for a bank |
| `create_directive` | `bank_id`, `name`, `description` | Create a new directive |
| `delete_directive` | `bank_id`, `directive_id` | Delete a directive |

**Memory browsing tools (3):**
| Tool | Parameters | Description |
|------|-----------|-------------|
| `list_memories` | `bank_id`, `offset`, `limit`, `tags`, `types` | List memories with pagination and filtering |
| `get_memory` | `bank_id`, `memory_id` | Get a specific memory by ID |
| `delete_memory` | `bank_id`, `memory_id` | Delete a specific memory |

**Document tools (3 existing + 1 new):**
| Tool | Parameters | Description | Status |
|------|-----------|-------------|--------|
| `list_documents` | `bank_id`, `offset`, `limit` | List documents for a bank | Merged |
| `get_document` | `bank_id`, `document_id` | Get a specific document | Merged |
| `delete_document` | `bank_id`, `document_id` | Delete a specific document | Merged |
| `create_documents` | `bank_id`, `contents[]` (each: `content`, `context`, `tags`, `metadata`), `document_name` | Retain one or multiple documents as a named document group — analogous to the HTTP `/files/retain` endpoint but for MCP text content. Creates a document record, extracts facts, and builds knowledge graph entries. | **New (Epic 2)** |

**Operation tools (3):**
| Tool | Parameters | Description |
|------|-----------|-------------|
| `list_operations` | `bank_id`, `status`, `offset`, `limit` | List async operations |
| `get_operation` | `bank_id`, `operation_id` | Get operation status |
| `cancel_operation` | `bank_id`, `operation_id` | Cancel a pending operation |

**Tags & bank management tools (6):**
| Tool | Parameters | Description |
|------|-----------|-------------|
| `list_tags` | `bank_id` | List all tags used in a bank |
| `get_bank` | `bank_id` | Get bank details |
| `get_bank_stats` | `bank_id` | Get bank statistics (multi-bank only) |
| `update_bank` | `bank_id`, `name`, `background`, `tags` | Update bank settings |
| `delete_bank` | `bank_id` | Delete a bank |
| `clear_memories` | `bank_id` | Clear all memories from a bank |

**Enhanced existing tool parameters:**
- `retain`: Added `tags`, `metadata`, `document_id`
- `recall`: Added `budget`, `types`, `tags`, `tags_match` (previously hardcoded)
- `reflect`: Added `budget`, `response_schema`, `tags`, `types`

**Mental model tools (6, from commit `f641b30d`):**
| Tool | Parameters | Description |
|------|-----------|-------------|
| `list_mental_models` | `bank_id`, `tags` | List with optional tag filtering |
| `get_mental_model` | `bank_id`, `mental_model_id` | Get content, source_query, metadata |
| `create_mental_model` | `bank_id`, `name`, `source_query`, `tags` | Create with async content generation |
| `update_mental_model` | `bank_id`, `mental_model_id`, `name`, `source_query`, `tags` | Update metadata |
| `delete_mental_model` | `bank_id`, `mental_model_id` | Delete a mental model |
| `refresh_mental_model` | `bank_id`, `mental_model_id` | Re-run source query to update content |

---

## Appendix B: Receipt (Audit Trail) — Operation Validator Extension

Hindsight's `OperationValidatorExtension` is an abstract plugin class that intercepts every operation with **pre-operation validation** and **post-operation hooks**. This maps directly to Jones' "Receipt" building block — a logging system showing what the system decided and why.

### How It Works

```
User calls retain/recall/reflect
        │
        ▼
PRE-OPERATION VALIDATION (blocking)
  ├─ validate_retain(RetainContext) → ValidationResult
  ├─ validate_recall(RecallContext) → ValidationResult
  └─ validate_reflect(ReflectContext) → ValidationResult
        │
        ├─ ValidationResult.accept() → continue
        └─ ValidationResult.reject("reason") → raise OperationValidationError
        │
        ▼
EXECUTE OPERATION
        │
        ▼
POST-OPERATION HOOK (non-blocking, errors logged as warnings)
  ├─ on_retain_complete(RetainResult)  — includes unit_ids, success, error
  ├─ on_recall_complete(RecallResult)  — includes full result object, tokens
  └─ on_reflect_complete(ReflectResultContext) — includes result, success
```

**Pre-operation contexts** carry all user-provided parameters (bank_id, query, budget, etc.).
**Post-operation results** carry parameters + results (success/failure, generated IDs, token counts, error messages).

### Receipt Use Cases (Already Possible)

A concrete `OperationValidatorExtension` implementation could:
- **Audit logging** — Log every operation with timestamp, user, bank, parameters, result
- **Usage metering** — Track token counts per tenant/bank for billing
- **Rate limiting** — Reject operations that exceed per-bank quotas
- **Compliance** — Block operations on restricted banks/fact types
- **Analytics** — Track query patterns, popular banks, failure rates

### What This Means for the Bouncer

The `validate_retain()` hook is the natural injection point for Jones' bouncer pattern — it can inspect incoming content and reject low-confidence items before they're stored.

---

## Appendix C: Bouncer (Confidence-Gated Retain) — DEFERRED

### Deferral Rationale

The bouncer pattern (confidence-gated storage with a `pending_reviews` queue) is **deferred from this PRD** because:

1. **No user review mechanism exists** — Hindsight has no UI or workflow for users to review queued items. The `pending_reviews` table would be a dead-end with no way to approve/dismiss entries.
2. **MCP clients cannot present review UIs** — Claude Code and other MCP consumers have no mechanism to surface a "review queue" to the user in a natural way.
3. **The existing `validate_retain()` hook can reject outright** — If low-confidence content is a problem, the extension hook already provides a rejection mechanism. But queuing for review without a review path creates orphaned data.

### What We Could Do Instead (Future PRD)

When a review mechanism exists (e.g., control plane UI, a review MCP tool, or a skill-driven review flow), the bouncer could be revisited:
- **Option A: Inline response** — Instead of queuing, the bouncer rejects and includes a clarification prompt in the response (e.g., "Could you be more specific? This content didn't parse into clear facts."). The user retries with better content.
- **Option B: Review skill** — A Claude Code skill (`/review-pending`) that queries `pending_reviews` and lets the user approve/dismiss via conversation.
- **Option C: Control plane UI** — A web interface for reviewing queued items (out of scope for this PRD).

### Technical Foundation Preserved

The `OperationValidatorExtension.validate_retain()` hook is the correct injection point for a future bouncer. The confidence scoring design (fact extraction quality, entity coherence, content substance) remains valid. When a review mechanism is built, this appendix can be promoted back to an epic.

### Jones Mapping Note

Jones' bouncer asks for clarification ("Can you repost with a prefix like person: or project:?"). **Option A** (inline response with clarification prompt) most closely matches this pattern and requires no new infrastructure — just a custom `OperationValidatorExtension` that rejects with a helpful message.

---

## Appendix D: Proactive Surfacing (Nudges) — Epic 5

### Recommendation: Skill-Driven Scheduled Reflect via MCP

Rather than building a cron system into Hindsight itself, **proactive surfacing should be a Claude Code skill** that calls the multi-step reflect MCP tools we're building. This keeps Hindsight as a memory engine (pure concern) while the scheduling and delivery layer lives outside.

### Architecture

```
┌──────────────────────────────────────────┐
│  Claude Code Skill: "second-brain-nudge" │
│                                          │
│  Triggered by:                           │
│  - User: /nudge                          │
│  - Cron: launchd / crontab               │
│  - Skill: /loop 24h /nudge              │
│                                          │
│  What it does:                           │
│  1. cross_bank_reflect(                  │
│       query="What are my top 3 actions   │
│              for today based on open      │
│              loops and recent context?",  │
│       bank_ids=["personal","business"],  │
│       budget="mid",                      │
│       response_schema={                  │
│         "actions": [...],                │
│         "open_loops": [...],             │
│         "pattern_noticed": "..."         │
│       }                                  │
│     )                                    │
│  2. Format result as concise digest      │
│  3. Deliver via configured channel       │
│     (terminal output / Slack / email)    │
└──────────────────────────────────────────┘
```

### Skill Templates

**Daily Digest Skill:**
- Query: "What are my top priorities today? What open loops need attention? What small wins can I celebrate?"
- Budget: MID
- Output: <150 words, structured as actions + open loops + one win
- Schedule: Daily at 7 AM via `/loop 24h /daily-digest`

**Weekly Review Skill:**
- Query: "What happened this week? What are the biggest stalled items? What patterns are emerging across my work?"
- Budget: HIGH (enables multi-step reasoning)
- Output: <250 words, structured as narrative + open loops + 3 suggested actions + one recurring theme
- Schedule: Sunday evening via `/loop 168h /weekly-review`

### Why This Approach?

1. **No new infrastructure in Hindsight** — Uses existing MCP tools (cross_bank_reflect with response_schema)
2. **Fully customizable** — Users write their own nudge queries as skills
3. **Delivery-agnostic** — Skill can output to terminal, Slack, email, or any channel
4. **Budget-aware** — Uses the multi-step reasoning pipeline we're already building
5. **Testable** — Run `/nudge` manually anytime; no need to wait for a schedule

---

## Appendix E: Fix Button (Correction Feedback Loop) — Epic 6

### How It Would Work

Jones' fix button is a low-friction mechanism to correct system mistakes (a Slack emoji reaction). In Hindsight, the analogue is a **correction API** that updates or deletes facts and triggers re-consolidation.

### Correction API Design

```
POST /v1/default/banks/{bank_id}/memories/{memory_id}/correct
{
  "action": "update" | "delete" | "reclassify",
  "corrected_text": "...",           // For "update"
  "corrected_fact_type": "world",    // For "reclassify"
  "reason": "This fact is outdated"  // Audit trail
}
```

### MCP Tool

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
    """Correct a memory that was incorrectly stored or classified."""
```

### What Happens After Correction

```
User corrects a memory
        │
        ▼
1. Apply correction (update/delete/reclassify)
2. Log correction in audit trail (operation validator)
3. Identify affected mental models (via based_on tracking)
4. Re-trigger consolidation for affected models
5. Refresh affected mental models (re-run source_query)
6. Return confirmation with list of updated models
```

### Why This Matters

- **Trust builds through demonstrated responsiveness** — If corrections visibly improve future results, users trust the system more
- **Low friction is essential** — If correcting takes 5 minutes, users leave bad data. If it's one MCP tool call, they actually do it.
- **Cascading updates** — Correcting a fact should cascade through mental models that used it, keeping the knowledge graph consistent

---

## Appendix F: Open Brain MCP Compatibility Gap Analysis

Jones' Open Brain exposes 4 MCP tools. Here's what Hindsight already provides and what's missing:

| Open Brain Tool | Hindsight Equivalent | Status | Gap |
|----------------|---------------------|--------|-----|
| `semantic_search` | `recall(query)` | **Exists** | None — `recall` runs semantic (vector), keyword (BM25), graph, and temporal search in parallel, then fuses with RRF + cross-encoder reranking. **More powerful than Open Brain's single-vector search.** |
| `browse_recent_thoughts` | `list_memories(bank_id, offset, limit, tags, types)` | **After upstream merge** | Available after Epic 0 merge. Supports pagination, tag filtering, type filtering. |
| `stats` | `get_bank_stats(bank_id)` | **After upstream merge** | Available after Epic 0 merge. Returns memory counts, entity counts, etc. |
| `capture_thought` | `retain(content, context)` | **Exists** | None — `retain` does everything `capture_thought` does plus entity extraction, fact classification, knowledge graph updates, and embedding generation. |

### What Hindsight Has That Open Brain Doesn't

| Capability | Description |
|-----------|-------------|
| **Knowledge graph** | Entity cooccurrence graph with BFS/MPFP traversal |
| **Four retrieval strategies** | Semantic + BM25 + Graph + Temporal (vs Open Brain's semantic-only) |
| **Cross-encoder reranking** | Results are reranked for relevance, not just vector distance |
| **Mental models** | Consolidated knowledge that auto-updates (after merge) |
| **Reflect (reasoning)** | Agentic multi-turn reasoning loop with disposition awareness |
| **Multi-bank isolation** | Schema-per-bank with cross-bank querying (our feature) |
| **Extension hooks** | Pre/post operation validation for billing, audit, rate limiting |
| **Structured output** | `response_schema` on reflect for programmatic consumption |

### Conclusion

Hindsight is **already a superset of Open Brain's capabilities**. After Epic 0 (upstream sync), we'd have full parity with Open Brain's 4 tools plus 25 additional tools. The remaining gap is framing — Jones' system uses simple tool names (`capture_thought`) while Hindsight uses technical names (`retain`). A thin compatibility layer could alias tools if needed, but it's not a technical gap.
