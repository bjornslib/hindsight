# SD-EPIC5-SECOND-BRAIN-SKILL: Solution Design — Second Brain Skill

**PRD:** PRD-SECONDBRAIN-001 (Epic 5)
**Status:** Draft (v0.1)
**Author:** Solution Architect
**Date:** 2026-03-16
**Version:** 0.1

---

## Table of Contents

1. [Overview and Goals](#1-overview-and-goals)
2. [Jones Building Blocks — Hindsight Mapping](#2-jones-building-blocks--hindsight-mapping)
3. [Skill Architecture](#3-skill-architecture)
4. [Bank Organization Strategy](#4-bank-organization-strategy)
5. [Response Schemas](#5-response-schemas)
6. [Mental Model Setup](#6-mental-model-setup)
7. [Directive Setup](#7-directive-setup)
8. [Migration Workflows](#8-migration-workflows)
9. [Onboarding Architecture](#9-onboarding-architecture)
10. [Skill File Structure](#10-skill-file-structure)
11. [Implementation Phases](#11-implementation-phases)
12. [Risk Assessment](#12-risk-assessment)
13. [Success Metrics](#13-success-metrics)

---

## 1. Overview and Goals

### What This Is

The Second Brain skill is a portable Claude Code skill (`.claude/skills/second-brain/`) that maps Nate B Jones' eight building blocks to Hindsight MCP tools, providing a structured workflow for Second Brain adopters. It is not a feature inside Hindsight itself — it is a consumer of Hindsight's existing MCP API surface.

The skill ships with all five of Jones' companion prompts reimplemented as slash commands, plus additional commands for daily nudges, weekly review synthesis, and brain health status. Any user who has the Hindsight MCP server configured can drop this skill into their `.claude/skills/` directory and immediately begin operating a Jones-style second brain.

### Goals

| Goal | How the Skill Achieves It |
|------|--------------------------|
| Make Hindsight the default Second Brain backend | Map Jones' vocabulary (Dropbox, Tap on the Shoulder, etc.) to Hindsight tools explicitly |
| Zero friction for new users | `/second-brain setup` provisions all banks, mental models, and directives in one pass |
| Immediately useful even with a single bank | All commands degrade gracefully: single-bank recall/reflect when no cross-bank setup exists |
| Match Jones' output specs exactly | Response schemas enforce <150-word daily digest, <250-word weekly review |
| Enable Jones' five companion prompts | Each companion prompt becomes a named command with Hindsight MCP calls specified |

### What This Skill Is Not

- Not a cron scheduler — it provides time-awareness via `brain-clock.sh` so the agent can suggest nudges and reviews at appropriate times; the user always decides whether to run them
- Not a database migration tool — it captures content from AI sessions and external knowledge bases via Hindsight's `retain` / `create_documents` API
- Not an extension to the Hindsight server — it runs entirely client-side in the MCP consumer

---

## 2. Jones Building Blocks — Hindsight Mapping

This section details how each of Jones' eight building blocks maps to Hindsight's capabilities. This mapping is the intellectual core of the skill and must be presented clearly to users in the skill's reference documentation.

### Block 1: The Dropbox (Frictionless Capture)

**Jones description:** A single capture point requiring no taxonomy decisions. Capturing takes under 3 seconds.

**Hindsight implementation:** `mcp__hindsight__retain(content, context?, tags?, bank_id?)`

The `retain` MCP tool is the exact analogue. Any MCP-connected client (Claude Code, Claude Desktop, Cursor) can call it inline with no routing decision. The skill's `/second-brain capture` command provides guided templates for the five most common capture types, but the raw `retain` call is always available without invoking the skill at all.

**Key principle enforced:** Jones mandates one capture point. The skill's setup guide instructs users to establish one "inbox" bank (`brain-inbox` or `personal`) as the single dropbox, regardless of how many domain banks they later create.

**Hindsight advantage over Jones' default (Slack channel):** Capture in Hindsight immediately triggers fact extraction, entity resolution, and knowledge graph linking. The content is already structured by the time the sorter runs — the sorter is the fact extraction pipeline itself.

### Block 2: The Sorter (Intelligent Classification)

**Jones description:** An AI step that classifies each captured thought into a category (Person, Project, Idea, Admin) and routes it to the right database.

**Hindsight implementation:** The fact extraction pipeline inside `retain()` — automatic, zero-configuration

Hindsight's retain pipeline does exactly what Jones' Zapier+Claude sorter does, but natively:

| Jones Step | Hindsight Equivalent | Location |
|-----------|---------------------|----------|
| Claude API call with classification prompt | Fact extraction LLM call | `retain/fact_extraction.py` |
| JSON: `destination`, `confidence`, `name` | Fact types: `world`, `experience`, `opinion`, `observation` | `retain/fact_extraction.py` |
| Entity extraction (person name, project) | Entity resolver | `entity_resolver.py` |
| Route to Person/Project/Ideas/Admin | Knowledge graph links by entity type | `retain/link_utils.py` |

**Jones' four categories → Hindsight's entity labels:**

| Jones Category | Hindsight Entity Label | Mental Model Created |
|---------------|----------------------|---------------------|
| Person | `person` entity type | "Who is [Name]" model |
| Project | `project` entity type | "Project: [Name]" model |
| Idea | `concept`/`topic` entity type | Captured as `opinion` facts |
| Admin | No entity, tagged `admin` | Raw facts with admin tag |

The skill does not need to implement routing logic — `retain` handles it. What the skill provides is the `/second-brain capture` command with five templates that prime the LLM to produce well-structured captures, improving fact extraction quality.

### Block 3: The Form (Standardized Structure)

**Jones description:** Field templates for each capture type (Person, Project, Idea, Admin). Templates give the classifier clear signals.

**Hindsight implementation:** Capture templates in `/second-brain capture` command

The skill provides five quick capture templates (see `references/capture-templates.md`) that structure the content before it reaches `retain`. Good structure at capture time produces higher-quality facts and better entity extraction. Templates follow Jones' field schema precisely:

| Template | Fields |
|----------|--------|
| Person note | Name, context of interaction, action items, follow-up date |
| Project note | Project name, current status, next concrete action, blockers |
| Idea note | The insight, what triggered it, related ideas or projects |
| Admin action | Action item, due date, context |
| Meeting note | Attendees, decisions made, action items with owners |

### Block 4: The Filing Cabinet (Persistent Memory Store)

**Jones description:** A source of truth with four tables (People, Projects, Ideas, Admin), writable by automation and readable by humans.

**Hindsight implementation:** Banks (PostgreSQL schemas) + pgvector + knowledge graph

Hindsight's bank architecture maps cleanly to Jones' Notion database approach:

| Jones (Notion) | Hindsight | Notes |
|---------------|-----------|-------|
| People database | Entity graph: `person` entities | Cross-queryable via entity recall |
| Projects database | Entity graph: `project` entities | Status tracked via mental models |
| Ideas database | `opinion`-type facts + concept entities | Vector-searchable |
| Admin database | Tagged facts (`tags: ["admin"]`) | Filterable via `tags` param on recall |
| inbox_log | `list_operations` + operation hooks | Full audit trail per retain |

**Multi-bank filing strategy** — see Section 4 for detailed bank organization.

### Block 5: The Receipt (Audit Trail)

**Jones description:** A log showing what the system classified each thought as, where it went, and the confidence score. Builds trust.

**Hindsight implementation:** `mcp__hindsight__list_operations` + `mcp__hindsight__list_memories`

Every `retain` call creates an operation record. The operation record contains the original content, the resulting memory unit IDs, success/failure status, and timestamps. Users can inspect classification decisions via:

```
mcp__hindsight__list_operations(bank_id="personal", status="completed")
mcp__hindsight__list_memories(bank_id="personal", limit=20)
```

The skill's `/second-brain status` command surfaces a human-readable audit view. The operation validator extension hook (`on_retain_complete`) also fires after every retain, enabling custom audit logging for multi-tenant deployments.

### Block 6: The Bouncer (Confidence Filter) — DEFERRED

**Jones description:** A quality gate that rejects low-confidence classifications and asks the user for clarification.

**Hindsight status:** Deferred (see PRD Appendix C). The `validate_retain()` extension hook is the correct injection point. No user review queue mechanism exists yet.

**Skill mitigation:** The `/second-brain capture` templates reduce the need for a bouncer by producing well-structured content that extracts cleanly. The skill includes guidance in `references/setup-guide.md` on how to interpret the operation log to catch misclassifications manually.

### Block 7: The Tap on the Shoulder (Proactive Surfacing)

**Jones description:** The system pushing useful information to the user without them searching. Two forms: Daily Digest and Weekly Review.

**Hindsight implementation:** THIS EPIC — the skill's primary value proposition

This is the core innovation of the Second Brain skill. Two commands deliver Jones' proactive surfacing pattern using `cross_bank_reflect` with structured `response_schema` output:

**Daily Digest (`/second-brain nudge`):**
- Calls `cross_bank_reflect` with budget=`mid`, all brain banks, response schema enforcing 3 actions + open loops + 1 win
- Output: under 150 words, phone-readable
- Scheduling: agent suggests at appropriate times via `brain-clock.sh` temporal context

**Weekly Review (`/second-brain review`):**
- Calls `cross_bank_reflect` with budget=`high` (enables multi-step decomposition), response schema enforcing narrative + open loops + 3 actions + 1 theme
- Output: under 250 words
- Scheduling: agent suggests on Monday mornings and Friday afternoons via `brain-clock.sh` temporal context

See Section 5 for the complete response schemas.

### Block 8: The Fix Button (Correction) — EPIC 6

**Jones description:** A low-friction mechanism (a Slack emoji) to correct misclassifications.

**Hindsight status:** Epic 6 (future PRD). The `delete_memory` and `update_bank` MCP tools provide manual correction capability today. The skill's `references/setup-guide.md` documents the correction workflow using existing tools:

```
mcp__hindsight__list_memories(bank_id, types=["experience"])  # Find the wrong memory
mcp__hindsight__delete_memory(bank_id, memory_id)             # Remove it
mcp__hindsight__retain(corrected_content, bank_id)            # Re-retain correctly
mcp__hindsight__refresh_mental_model(bank_id, model_id)       # Update affected models
```

---

## 3. Skill Architecture

### Command Surface

| Command | Alias | Jones Companion | Budget | Primary MCP Calls |
|---------|-------|----------------|--------|-------------------|
| `/second-brain setup` | — | — | — | `list_banks`, `create_bank`, `create_mental_model`, `create_directive` |
| `/second-brain capture` | `/capture` | Quick Capture Templates | — | `retain` or `create_documents` |
| `/second-brain migrate` | `/migrate` | Memory Migration | low | `retain` (batched) |
| `/second-brain import` | `/import` | Second Brain Migration | low | `create_documents` |
| `/second-brain spark` | `/spark` | Open Brain Spark | mid | `cross_bank_reflect` |
| `/second-brain nudge` | `/nudge` | — (Daily Digest) | mid | `cross_bank_reflect` |
| `/second-brain review` | `/weekly-review` | Weekly Review Ritual | high | `cross_bank_reflect` |
| `/second-brain status` | `/brain-status` | — | — | `get_bank_stats`, `list_mental_models`, `list_memories` |
| `/second-brain onboard` | `/onboard` | Open Brain Spark (extended) | mid | `get_bank_stats`, `retain`, `create_mental_model`, `cross_bank_reflect` |

### Command Workflows

#### `/second-brain setup`

Provisions the Second Brain configuration from scratch. Safe to re-run — checks for existing resources before creating.

```
Step 1: Discover existing state
  mcp__hindsight__list_banks()
  → Record which banks already exist
  → Filter for banks with tag "second-brain"

Step 2: Create missing standard banks
  If "personal" bank missing:
    mcp__hindsight__create_bank(
      bank_id="personal",
      name="Personal Brain",
      background="This bank contains personal context: relationships, personal projects, health, finances, and life goals. Facts here are private and personal.",
      tags=["second-brain"]
    )
  If "work" bank missing:
    mcp__hindsight__create_bank(
      bank_id="work",
      name="Work Brain",
      background="This bank contains work context: professional projects, colleagues, business goals, and work-related knowledge.",
      tags=["second-brain"]
    )

Step 3: Create standard mental models per bank
  For each bank_id in ["personal", "work"]:
    mcp__hindsight__list_mental_models(bank_id=bank_id)
    → Check which standard models already exist (skip duplicates)

    If "Personal context" missing:
      mcp__hindsight__create_mental_model(
        bank_id=bank_id,
        name="Personal context",
        description="What are the key facts about who I am, my background, values, and goals?"
      )
    If "Active projects" missing:
      mcp__hindsight__create_mental_model(
        bank_id=bank_id,
        name="Active projects",
        description="What are my current active projects, their status, and next actions?"
      )
    If "Key people" missing:
      mcp__hindsight__create_mental_model(
        bank_id=bank_id,
        name="Key people",
        description="Who are the most important people in my context — their roles, relationship to me, and any current commitments?"
      )
    If "Open loops" missing:
      mcp__hindsight__create_mental_model(
        bank_id=bank_id,
        name="Open loops",
        description="What are my unfinished commitments, pending decisions, and open questions? Include anything mentioned more than once without resolution."
      )

Step 4: Create standard directives per bank
  For each bank_id in ["personal", "work"]:
    mcp__hindsight__list_directives(bank_id=bank_id)
    → Check which standard directives already exist (skip duplicates)

    If "Capture quality" missing:
      mcp__hindsight__create_directive(
        bank_id=bank_id,
        name="Capture quality",
        description="When retaining content, always extract specific names, dates, and next actions. Prefer concrete facts over vague summaries. 'Met with Sarah to discuss Q2 planning' is better than 'Had a meeting'."
      )
    If "Privacy boundary" missing:
      mcp__hindsight__create_directive(
        bank_id=bank_id,
        name="Privacy boundary",
        description="This bank contains [personal/work] context. Facts extracted here belong to this context only. Do not generalize beyond the subject matter of this bank."
      )

Step 5: Output setup summary
  mcp__hindsight__list_banks()
  → For each bank with tag "second-brain":
    mcp__hindsight__get_bank_stats(bank_id=bank_id)
    mcp__hindsight__list_mental_models(bank_id=bank_id)
    mcp__hindsight__list_directives(bank_id=bank_id)
  → Format: "Setup complete. Banks: [list]. Models per bank: [count]. Directives per bank: [count]."
```

#### `/second-brain capture`

Presents a guided capture interface based on Jones' five templates. Defaults to `retain` for single items, `create_documents` for multi-item captures.

```
Step 1: Ask capture type (conversational — no MCP calls)
  "What type of capture? [person / project / idea / meeting / admin]"

Step 2: Load template from references/capture-templates.md (no MCP calls)
  Use the template fields to guide the conversation.

Step 3: Gather fields via conversation (max 3 turns, no MCP calls)
  Ask for template-specific fields (e.g., for person: Name, context, action items, follow-up date).

Step 4: Construct content string from template (no MCP calls)
  Format the gathered fields into a structured content string.

Step 5: Determine target bank
  mcp__hindsight__list_banks()
  → Filter for banks with tag "second-brain"
  → If person/meeting content mentions work context → bank_id="work"
  → If personal content → bank_id="personal"
  → If only one bank exists → use that bank
  → If ambiguous, ask user: "Should this go in your personal or work brain?"

Step 6: Retain the capture
  mcp__hindsight__retain(
    content="<structured content from template>",
    context="<capture_type> capture",
    tags=["<capture_type>", "second-brain"],
    bank_id="<selected bank>"
  )

Step 7: Confirm capture
  → "Captured to [bank_id]. Memory ID: [returned_id]."
  → If capture_type is "person" and this is a new person:
    "Tip: This person will appear in your Key People mental model after the next refresh."
```

#### `/second-brain migrate`

Extracts key facts from the current AI conversation context and retains them into Hindsight. Jones' "Memory Migration" companion prompt.

```
Step 1: Self-reflect on conversation context (no MCP calls — pure LLM reasoning)
  Analyze the current conversation and extract:
  - Named people, projects, decisions, preferences, commitments, recurring themes
  - Format each as a one-sentence fact suitable for long-term memory
  - Categorize each as: [person] / [project] / [preference] / [decision] / [commitment]

Step 2: Present candidate list to user (no MCP calls)
  "I found N items worth retaining:"
  "[person] Sarah is considering a career transition to consulting."
  "[project] The website redesign is blocked on content from design team."
  "[preference] You prefer async-first communication styles."
  "Shall I capture all, or select specific items?"

Step 3: User approves/rejects individual items (no MCP calls)
  → User selects which items to retain

Step 4: Determine target banks
  mcp__hindsight__list_banks()
  → Filter for banks with tag "second-brain"
  → For each approved item, assign bank based on content:
    - Work-related items → bank_id="work"
    - Personal items → bank_id="personal"
    - If only one bank → use that bank

Step 5: Batch retain approved items
  For each approved item:
    mcp__hindsight__retain(
      content="<extracted fact>",
      context="Migrated from AI conversation on <today's date>",
      tags=["migrated", "second-brain", "<category>"],
      bank_id="<assigned bank>"
    )

Step 6: Summary
  "Retained N memories across [bank_count] banks."
  "Run /second-brain status to verify."
```

#### `/second-brain import`

Imports content from external knowledge bases (Notion exports, Obsidian vaults, markdown files). Jones' "Second Brain Migration" companion prompt.

```
Step 1: Ask source system (conversational — no MCP calls)
  "What are you importing from? [Notion export / Obsidian vault / Markdown files / other]"

Step 2: Ask for file path or pasted content (no MCP calls)
  "Paste the file path or directory, or paste the content directly."

Step 3: Determine target bank
  mcp__hindsight__list_banks()
  → Filter for banks with tag "second-brain"
  → Ask user which bank to import into, or auto-select based on content type

Step 4a: If file-based import
  For each file:
    - Read file content
    - Chunk at semantic boundaries (H2 headings, or ~500-word chunks)
    - mcp__hindsight__create_documents(
        bank_id="<target bank>",
        document_name="<source filename, e.g. 'meeting-notes-2026-03.md'>",
        contents=[
          {
            "content": "<chunk_text>",
            "context": "Imported from <source_system> on <today's date>",
            "tags": ["imported", "<source_system>"]
          }
        ]
      )

Step 4b: If pasted content
  mcp__hindsight__retain(
    content="<pasted content>",
    context="Imported from <source_system> on <today's date>",
    tags=["imported", "<source_system>", "second-brain"],
    bank_id="<target bank>"
  )

Step 5: Post-import verification
  mcp__hindsight__list_documents(bank_id="<target bank>")
  → Verify document count matches expected file count
  mcp__hindsight__get_bank_stats(bank_id="<target bank>")
  → Report new memory count

Step 6: Summary
  "Imported N documents into [bank_id]. Facts are being extracted in the background."
  "Tip: Run /second-brain status in 60 seconds to see extracted memories."
```

#### `/second-brain spark`

Discovers personalized use cases and generates the user's "First 20 Captures". Jones' "Open Brain Spark" companion prompt.

```
Step 1: Identify brain banks
  mcp__hindsight__list_banks()
  → Filter for banks with tag "second-brain"
  → Collect bank_ids (e.g., ["personal", "work"])

Step 2: Generate personalized capture suggestions
  mcp__hindsight__cross_bank_reflect(
    query="Based on what you know about me, what are the 20 most valuable things I could capture in my second brain right now? Consider my active projects, key relationships, open questions, and goals. For each suggestion, be specific — not 'capture project info' but 'capture the current status of [specific project]'.",
    bank_ids=["personal", "work"],
    budget="mid",
    response_schema={
      "type": "object",
      "required": ["captures", "personalized_insight"],
      "properties": {
        "captures": {
          "type": "array",
          "minItems": 15,
          "maxItems": 20,
          "items": {
            "type": "object",
            "required": ["content", "category", "why_valuable"],
            "properties": {
              "content": {"type": "string", "maxLength": 200},
              "category": {"type": "string", "enum": ["person", "project", "idea", "admin", "meeting"]},
              "why_valuable": {"type": "string", "maxLength": 150}
            }
          }
        },
        "personalized_insight": {"type": "string", "maxLength": 300}
      }
    }
  )
  → If cross_bank_reflect unavailable, fall back to:
    mcp__hindsight__reflect(
      query="<same query as above>",
      bank_id="personal",
      budget="mid",
      response_schema=<same schema>
    )

Step 3: Present suggestions to user (no MCP calls)
  Format each capture with its category and rationale.
  "Which of these would you like to capture now? (Pick numbers, or 'all')"

Step 4: Retain selected captures
  For each selected item:
    mcp__hindsight__retain(
      content="<capture content>",
      context="Sparked capture — <category>",
      tags=["sparked", "second-brain", "<category>"],
      bank_id="<personal or work based on category — person/idea → personal, project/admin/meeting → work>"
    )

Step 5: Summary
  "Captured N items. Your brain now has [new_total] memories."
  "Tip: Run /nudge tomorrow morning to see how these feed into your daily digest."
```

#### `/second-brain nudge` (Daily Digest)

The primary "Tap on the Shoulder" implementation. Delivers Jones' daily digest in under 150 words.

```
Step 1: Identify brain banks
  mcp__hindsight__list_banks()
  → Filter for banks with tag "second-brain"
  → Collect bank_ids (e.g., ["personal", "work"])

Step 2: Generate daily digest
  mcp__hindsight__cross_bank_reflect(
    query="What are my top 3 action items for today? What open loops need attention? What small win from recent activity should I celebrate? Be specific — use names, dates, and concrete next steps.",
    bank_ids=["personal", "work"],
    budget="mid",
    response_schema={
      "type": "object",
      "required": ["actions", "open_loop", "win"],
      "properties": {
        "actions": {
          "type": "array",
          "minItems": 3,
          "maxItems": 3,
          "items": {
            "type": "object",
            "required": ["action", "context"],
            "properties": {
              "action": {"type": "string", "maxLength": 100},
              "context": {"type": "string", "maxLength": 150}
            }
          }
        },
        "open_loop": {
          "type": "object",
          "required": ["description", "stale_since"],
          "properties": {
            "description": {"type": "string", "maxLength": 120},
            "stale_since": {"type": "string"}
          }
        },
        "win": {"type": "string", "maxLength": 100},
        "total_word_count": {"type": "integer"}
      }
    }
  )
  → If cross_bank_reflect unavailable, fall back to:
    mcp__hindsight__reflect(
      query="<same query>",
      bank_id="personal",
      budget="mid",
      response_schema=<same schema>
    )

Step 3: Format and present (no MCP calls)
  "--- Second Brain Daily Digest ---
  TOP ACTIONS:
  1. [action + context]
  2. [action + context]
  3. [action + context]

  OPEN LOOP: [description] (stale since [stale_since])

  WIN: [win]
  ---"
  → Verify total_word_count < 150; trim if needed
```

#### `/second-brain review` (Weekly Review)

Jones' weekly review ritual. Higher budget enables multi-step decomposition.

```
Step 1: Identify brain banks
  mcp__hindsight__list_banks()
  → Filter for banks with tag "second-brain"
  → Collect bank_ids (e.g., ["personal", "work"])

Step 2: Refresh key mental models before synthesis
  For each bank_id in bank_ids:
    mcp__hindsight__list_mental_models(bank_id=bank_id)
    → Find "Active projects" model → get its model_id
    mcp__hindsight__refresh_mental_model(bank_id=bank_id, model_id="<active-projects-model-id>")
    → Find "Open loops" model → get its model_id
    mcp__hindsight__refresh_mental_model(bank_id=bank_id, model_id="<open-loops-model-id>")

Step 3: Generate weekly review
  mcp__hindsight__cross_bank_reflect(
    query="Synthesize what happened this week across all my contexts. What were the key events? What are my biggest stalled items? What patterns are emerging in my work and life? What should I focus on next week? Be specific — use names, dates, and concrete actions.",
    bank_ids=["personal", "work"],
    budget="high",
    response_schema={
      "type": "object",
      "required": ["narrative", "open_loops", "next_week_actions", "theme"],
      "properties": {
        "narrative": {"type": "string", "maxLength": 400},
        "open_loops": {
          "type": "array",
          "minItems": 1,
          "maxItems": 4,
          "items": {
            "type": "object",
            "required": ["item", "urgency"],
            "properties": {
              "item": {"type": "string", "maxLength": 120},
              "urgency": {"type": "string", "enum": ["this week", "this month", "someday"]}
            }
          }
        },
        "next_week_actions": {
          "type": "array",
          "minItems": 3,
          "maxItems": 3,
          "items": {
            "type": "object",
            "required": ["action", "why"],
            "properties": {
              "action": {"type": "string", "maxLength": 100},
              "why": {"type": "string", "maxLength": 150}
            }
          }
        },
        "theme": {"type": "string", "maxLength": 150},
        "total_word_count": {"type": "integer"}
      }
    }
  )
  → If cross_bank_reflect unavailable, fall back to:
    mcp__hindsight__reflect(
      query="<same query>",
      bank_id="personal",
      budget="high",
      response_schema=<same schema>
    )

Step 4: Format and present (no MCP calls)
  "--- Second Brain Weekly Review ---
  THIS WEEK: [narrative]

  OPEN LOOPS:
  - [item] (urgency: [urgency])
  - [item] (urgency: [urgency])

  NEXT WEEK:
  1. [action] — [why]
  2. [action] — [why]
  3. [action] — [why]

  THEME: [theme]
  ---"
  → Verify total_word_count < 250; trim if needed
```

#### `/second-brain status`

Brain health dashboard. No LLM calls — pure data retrieval.

```
Step 1: List all brain banks
  mcp__hindsight__list_banks()
  → Filter for banks with tag "second-brain"

Step 2: Gather stats per bank
  For each bank_id in brain banks:
    mcp__hindsight__get_bank_stats(bank_id=bank_id)
    → Record: total_memories, total_entities, total_documents
    mcp__hindsight__list_mental_models(bank_id=bank_id)
    → Record: model count and names

Step 3: Get recent captures for primary bank
  mcp__hindsight__list_memories(bank_id="personal", limit=5)
  → Record: last capture timestamp and truncated content

Step 4: Format dashboard (no MCP calls)
  "--- Second Brain Status ---
  Banks: N active
  personal: [N] memories, [N] entities, [N] mental models
  work: [N] memories, [N] entities, [N] mental models
  Last capture: [timestamp] — [truncated content preview]
  Mental models: [list of model names across all banks]
  ---"
```

#### `/second-brain onboard` (Progressive Onboarding)

Full onboarding flow for fresh brains. See Section 9 for the detailed architecture and the full workflow below for exact MCP calls.

```
Step 1: Detect fresh brain
  mcp__hindsight__get_bank_stats(bank_id="personal")
  → If total_memories == 0: proceed with onboarding
  → If total_memories >= 20: suggest /spark instead

Step 2: Run setup if needed
  mcp__hindsight__list_banks()
  → If "personal" bank missing:
    mcp__hindsight__create_bank(
      bank_id="personal",
      name="Personal Brain",
      background="Personal knowledge, experiences, relationships, and insights",
      tags=["second-brain"]
    )
  → If "work" bank missing:
    mcp__hindsight__create_bank(
      bank_id="work",
      name="Work Brain",
      background="Professional context, projects, decisions, and team dynamics",
      tags=["second-brain"]
    )

Step 3: Discovery interview (conversational — no MCP calls, pure conversation)
  Ask 5 questions (see Section 9 for the full question list):
  1. "What tools do you use daily (especially which ones don't talk to each other)?"
  2. "What kind of decisions do you make repeatedly?"
  3. "What information do you find yourself re-explaining to AI?"
  4. "What do you forget that costs you time?"
  5. "Who do you work with regularly?"
  → Classify role from answers: PM, engineer, writer, or general/mixed

Step 4: Retain discovery answers as first memories
  For each substantive answer:
    mcp__hindsight__retain(
      content="<structured answer, e.g. 'Uses Figma, Linear, Slack daily. Figma and Linear do not share context.'>",
      context="Onboarding discovery — question N",
      tags=["onboarding", "discovery"],
      bank_id="personal"
    )
  For work-specific answers (tools, colleagues, projects):
    mcp__hindsight__retain(
      content="<structured answer>",
      context="Onboarding discovery — question N",
      tags=["onboarding", "discovery"],
      bank_id="work"
    )

Step 5: Generate "First 20 Captures" tailored to detected role
  mcp__hindsight__cross_bank_reflect(
    query="Based on what you know about me from onboarding, generate 20 specific things I should capture in my Second Brain this week. Tailor to my role as [detected_role]. For each, specify the category and a concrete example.",
    bank_ids=["personal", "work"],
    budget="mid",
    response_schema={
      "type": "object",
      "properties": {
        "role_detected": {"type": "string"},
        "captures": {
          "type": "array",
          "minItems": 15,
          "maxItems": 20,
          "items": {
            "type": "object",
            "properties": {
              "category": {"type": "string"},
              "suggestion": {"type": "string"},
              "example": {"type": "string"},
              "template": {"type": "string", "enum": ["person", "project", "insight", "meeting", "action"]}
            }
          }
        }
      }
    }
  )
  → If cross_bank_reflect unavailable, fall back to:
    mcp__hindsight__reflect(
      query="<same query>",
      bank_id="personal",
      budget="mid",
      response_schema=<same schema>
    )

Step 6: Guide user through first 3-5 captures
  Present the "First 20 Captures" list. Ask: "Let's capture 3-5 of these now. Which ones?"
  For each capture the user provides:
    mcp__hindsight__retain(
      content="<formatted using appropriate template from references/capture-templates.md>",
      context="<category> — onboarding capture",
      tags=["onboarding", "<category>", "second-brain"],
      bank_id="<personal or work based on content>"
    )

Step 7: Magic moment — create first mental model
  mcp__hindsight__create_mental_model(
    bank_id="personal",
    name="Who I am",
    description="Comprehensive synthesis of who this person is — their role, interests, working style, key relationships, and current priorities. Based on onboarding discovery and initial captures."
  )
  mcp__hindsight__refresh_mental_model(bank_id="personal", model_id="<returned model_id>")
  mcp__hindsight__get_mental_model(bank_id="personal", model_id="<returned model_id>")
  → Present the refreshed mental model content to the user:
    "Here's what your Second Brain knows about you: [model content]"

Step 8: Output summary
  "Your Second Brain is alive. It knows [N] facts about you across [bank_count] banks."
  "Run /nudge tomorrow morning for your first daily digest."
```

#### Time-Aware Nudging (via `brain-clock.sh`)

Instead of OS-level scheduling, the skill uses a simple time-awareness approach. At session start, the agent runs `scripts/brain-clock.sh` to get temporal context and proactively offers relevant commands.

```
Step 1: At session start, run brain-clock.sh (Bash, no MCP calls)
  bash .claude/skills/second-brain/scripts/brain-clock.sh
  → Outputs key-value pairs: date, day, hour, nudge_window, daily_nudge, weekly_review, monthly_review

Step 2: Based on temporal context, proactively suggest (no MCP calls)
  If daily_nudge == "recommended" (morning window 7-10am):
    "Good morning! Want your daily digest? /nudge"
  If nudge_window == "evening" (5-7pm):
    "End of day — want a quick digest before you wrap up? /nudge"
  If weekly_review == "recommended" (Monday morning or Friday afternoon):
    "It's [Monday/Friday] — want your weekly review? /review"
  If monthly_review == "approaching" (day >= 28):
    "Month-end approaching — consider a deeper review of your mental models."

Step 3: User decides (no MCP calls)
  The agent suggests, the user decides. No automated scheduling needed.
```

This approach works with any MCP client, requires no OS-level setup, and the user can customize `brain-clock.sh` to match their timezone and preferred windows.

### Single-Bank Degradation

All commands that call `cross_bank_reflect` fall back gracefully:

- If user has only one bank, call single-bank `reflect` instead
- If `bank_ids` list is empty, default to `bank_id="personal"` (or first available bank)
- If cross-bank MCP tools are unavailable, emit a warning and use single-bank tools

This means the skill is immediately useful after `/second-brain setup` with a single bank, even before the user creates a multi-bank configuration.

---

## 4. Bank Organization Strategy

### Recommended Default Configuration

The skill recommends two banks for most users. This matches Jones' design: personal and professional contexts should be isolatable but queryable together.

| Bank ID | Name | Purpose | Background |
|---------|------|---------|------------|
| `personal` | Personal Brain | Life context, relationships, personal projects, health, goals | "This bank contains personal context: relationships, personal projects, health, finances, and life goals. Facts here are private and personal." |
| `work` | Work Brain | Professional context, work projects, colleagues, business goals | "This bank contains work context: professional projects, colleagues, business goals, and work-related knowledge." |

### Single-Bank Alternative

For users who want to start simply:

| Bank ID | Name | Purpose |
|---------|------|---------|
| `brain` | My Brain | Everything |

The skill's `/second-brain setup` asks: "Do you want one combined brain or separate personal/work banks?" One-bank setup requires no cross-bank tools — simpler and immediately operational.

### Domain-Specific Extensions (Optional)

Power users may add domain banks. The skill does not prescribe these but documents common patterns in `references/setup-guide.md`:

| Bank ID | Purpose | Example Background |
|---------|---------|-------------------|
| `research` | Academic/reading captures | "Research notes, paper summaries, intellectual exploration" |
| `health` | Health tracking | "Health data, fitness goals, medical notes" |
| `finance` | Financial tracking | "Financial tracking, budget notes, investment ideas" |

### Bank Tag Strategy

All Second Brain banks should be tagged `second-brain` to enable tag-based cross-bank queries:

```python
cross_bank_reflect(
    query="...",
    bank_tags=["second-brain"],  # Query all Second Brain banks
    budget="mid"
)
```

This means adding a third bank later (e.g., `research`) automatically joins cross-bank queries without reconfiguring the skill.

### Why Not One Bank Per Jones Category?

Jones uses four Notion databases (People, Projects, Ideas, Admin). Hindsight should not mirror this as four banks because:

1. Entity types already separate People vs Projects vs Ideas within a single bank
2. Mental models per entity type provide the same isolation Notion tables provide
3. Cross-bank reflect carries overhead — intra-bank entity queries are faster and cheaper
4. A "People bank" vs "Projects bank" split loses the ability to link a person to a project in a single recall

The correct analogue is: Jones' four Notion tables = Hindsight's entity type graph within one bank.

---

## 5. Response Schemas

### Nudge Schema (Daily Digest)

Used by `/second-brain nudge`. Enforces Jones' <150-word format.

```json
{
  "type": "object",
  "required": ["actions", "open_loop", "win"],
  "properties": {
    "actions": {
      "type": "array",
      "minItems": 3,
      "maxItems": 3,
      "items": {
        "type": "object",
        "required": ["action", "context"],
        "properties": {
          "action": {
            "type": "string",
            "description": "A specific, executable action (not vague — not 'work on X', but 'email Sarah about X deadline')",
            "maxLength": 100
          },
          "context": {
            "type": "string",
            "description": "One sentence of context explaining why this action matters now",
            "maxLength": 150
          }
        }
      }
    },
    "open_loop": {
      "type": "object",
      "required": ["description", "stale_since"],
      "properties": {
        "description": {
          "type": "string",
          "description": "The unfinished commitment or open question",
          "maxLength": 120
        },
        "stale_since": {
          "type": "string",
          "description": "Approximate timeframe this has been open (e.g., 'last Tuesday', 'two weeks')"
        }
      }
    },
    "win": {
      "type": "string",
      "description": "One small win or positive development from recent memory to celebrate",
      "maxLength": 100
    },
    "total_word_count": {
      "type": "integer",
      "description": "Approximate word count of the formatted output — must be under 150"
    }
  }
}
```

### Review Schema (Weekly Review)

Used by `/second-brain review`. Enforces Jones' <250-word format.

```json
{
  "type": "object",
  "required": ["narrative", "open_loops", "next_week_actions", "theme"],
  "properties": {
    "narrative": {
      "type": "string",
      "description": "What happened this week — 3-4 sentences covering key events, decisions, and progress",
      "maxLength": 400
    },
    "open_loops": {
      "type": "array",
      "minItems": 1,
      "maxItems": 4,
      "items": {
        "type": "object",
        "required": ["item", "urgency"],
        "properties": {
          "item": {
            "type": "string",
            "description": "Stalled action item or unresolved question",
            "maxLength": 120
          },
          "urgency": {
            "type": "string",
            "enum": ["this week", "this month", "someday"],
            "description": "When this needs resolution"
          }
        }
      }
    },
    "next_week_actions": {
      "type": "array",
      "minItems": 3,
      "maxItems": 3,
      "items": {
        "type": "object",
        "required": ["action", "why"],
        "properties": {
          "action": {
            "type": "string",
            "description": "Specific, executable action for next week",
            "maxLength": 100
          },
          "why": {
            "type": "string",
            "description": "One sentence rationale grounded in this week's context",
            "maxLength": 150
          }
        }
      }
    },
    "theme": {
      "type": "string",
      "description": "One recurring pattern or theme the system noticed across this week's memories — something the user might not have noticed themselves",
      "maxLength": 150
    },
    "total_word_count": {
      "type": "integer",
      "description": "Approximate word count of the formatted output — must be under 250"
    }
  }
}
```

### Spark Schema (Open Brain Spark)

Used by `/second-brain spark`.

```json
{
  "type": "object",
  "required": ["captures", "personalized_insight"],
  "properties": {
    "captures": {
      "type": "array",
      "minItems": 15,
      "maxItems": 20,
      "items": {
        "type": "object",
        "required": ["content", "category", "why_valuable"],
        "properties": {
          "content": {
            "type": "string",
            "description": "The specific content to retain — specific enough to be actionable",
            "maxLength": 200
          },
          "category": {
            "type": "string",
            "enum": ["person", "project", "idea", "admin", "meeting"]
          },
          "why_valuable": {
            "type": "string",
            "description": "One sentence explaining why this specific memory will make the second brain more useful",
            "maxLength": 150
          }
        }
      }
    },
    "personalized_insight": {
      "type": "string",
      "description": "A 2-3 sentence observation about the user's knowledge gaps or opportunities based on what the system does and doesn't know",
      "maxLength": 300
    }
  }
}
```

---

## 6. Mental Model Setup

The `/second-brain setup` command creates four standard mental models per bank. These models are the "pinned reflections" that give cross-bank reflect high-quality context without requiring every query to run a full fact scan.

### Standard Mental Models

| Model Name | Source Query | Refresh Cadence | Why |
|-----------|-------------|----------------|-----|
| Personal context | "What are the key facts about who I am, my background, values, and goals?" | Weekly | Stable self-context for all reflect queries |
| Active projects | "What are my current active projects, their status, and next actions?" | Daily (auto-triggers on retain) | High-churn — changes as work progresses |
| Key people | "Who are the most important people in my context — their roles, relationship to me, and any current commitments?" | Weekly | Relationship context for nudges |
| Open loops | "What are my unfinished commitments, pending decisions, and open questions?" | Daily | The most critical model for nudge and review quality |

### Model Creation Call

```python
mcp__hindsight__create_mental_model(
    bank_id="personal",
    name="Open loops",
    description="What are my unfinished commitments, pending decisions, and open questions? Include anything that has been mentioned more than once without a resolution."
)
```

### Mental Model Refresh Strategy

The `refresh_mental_model` call re-runs the `source_query` against current facts. The skill recommends:

- **"Active projects" and "Open loops" models**: refresh after each `/second-brain review` to ensure the weekly review reflects fresh synthesis
- **"Personal context" and "Key people" models**: refresh monthly or when significant new facts are retained about identity or relationships
- `/second-brain review` automatically refreshes "Active projects" and "Open loops" before generating the weekly synthesis

### Cross-Bank Mental Model Access

When `cross_bank_reflect` runs, it includes mental models from all queried banks. This means:
- `personal` bank's "Key people" model contributes context about personal relationships
- `work` bank's "Key people" model contributes context about professional relationships
- The reflect LLM receives both, attributed by bank

No special configuration is needed — mental models participate in cross-bank reflect automatically.

---

## 7. Directive Setup

Directives are persistent instructions that modify how a bank's retain and reflect operations behave. The skill creates two standard directives per bank.

### Standard Directives

| Directive Name | Content | Purpose |
|---------------|---------|---------|
| Capture quality | "When retaining content, always extract specific names, dates, and next actions. Prefer concrete facts over vague summaries. 'Met with Sarah to discuss Q2 planning' is better than 'Had a meeting'." | Improves fact extraction signal |
| Privacy boundary | "This bank contains [personal/work] context. Facts extracted here belong to this context only. Do not generalize beyond the subject matter of this bank." | Guides disposition-aware reflect |

### Directive Creation Call

```python
mcp__hindsight__create_directive(
    bank_id="personal",
    name="Capture quality",
    description="When retaining content, always extract specific names, dates, and next actions. Prefer concrete facts over vague summaries. 'Met with Sarah to discuss Q2 planning' is better than 'Had a meeting'."
)
```

### Optional Advanced Directives

Users may add these after initial setup (documented in `references/setup-guide.md`):

| Directive | Content | When to Use |
|----------|---------|------------|
| Time horizon | "When surfacing open loops, prioritize items from the last 30 days unless marked as long-term." | Users with large history wanting recency bias |
| Focus area | "Current focus: [Q1 2026 launch / career transition / health goals]. Weight recent facts about this area more heavily." | Users in a specific life phase |
| Weekly review anchor | "The weekly review covers Sunday through Saturday. Facts retained after Saturday count for next week." | Users who want precise week boundaries |

---

## 8. Migration Workflows

### 8.1 Memory Migration (From AI Sessions)

**Use case:** User has had months of conversations with Claude/ChatGPT that contain valuable context, decisions, and commitments. They want to seed their Second Brain without manually re-typing everything.

**Workflow:**

```
Step 1: User initiates /second-brain migrate in a session with existing context

Step 2: Skill runs a self-reflection pass:
  "Identify every named person, project, decision, preference, commitment,
   and recurring theme mentioned in this conversation. Format each as a
   one-sentence fact suitable for long-term memory."

Step 3: Generate candidate memory list (5-20 items)

Step 4: Present to user with category suggestion:
  "[person] Sarah is considering a career transition to consulting."
  "[project] The website redesign is blocked on content from design team."
  "[preference] User prefers async-first communication styles."

Step 5: User approves/rejects individual items (or approves all)

Step 6: Batch retain approved items:
  retain(content, context="Migrated from AI conversation on [date]", tags=["migrated"])

Step 7: Report: "Retained N memories. Your second brain now knows about [key entities]."
```

**Implementation note:** Step 2 runs as an LLM prompt in-context — no Hindsight calls needed. The extraction happens before the first `retain` call. This is important: the skill is doing the equivalent of Jones' sorter before capture, which produces higher-quality facts than raw conversational content.

### 8.2 Second Brain Migration (From External Tools)

**Use case:** User has an existing Notion database, Obsidian vault, or collection of markdown files they want to import into Hindsight.

**Supported sources:**

| Source | Import Method | Notes |
|--------|-------------|-------|
| Notion CSV export | `create_documents` with chunked rows | Each row = one document |
| Obsidian vault | `create_documents` with per-file documents | Each `.md` file = one document |
| Plain markdown files | `create_documents` | Chunk at H2 boundaries |
| Apple Notes export | `retain` individual notes | Paste content manually |
| Roam Research JSON | `create_documents` | Each block = one document entry |

**Core pattern:**

```python
# For file-based import
mcp__hindsight__create_documents(
    bank_id="personal",
    document_name=<filename or source label>,
    contents=[
        {
            "content": <chunk_text>,
            "context": f"Imported from {source} on {date}",
            "tags": ["imported", source_tag]
        }
        for chunk_text in chunks
    ]
)
```

**Chunking strategy:**
- Notion pages: one document per page, sections as multiple `contents` entries
- Obsidian notes: one document per file; chunk at H2 headings if >1000 words
- Markdown: chunk at H2 boundaries or every 500 words, whichever is smaller

**Post-import verification:**
```
/second-brain status  # Check memory counts
mcp__hindsight__list_documents(bank_id)  # Verify document records
mcp__hindsight__list_memories(bank_id, limit=10)  # Inspect extracted facts
```

### 8.3 Ongoing Capture (Daily Use)

After initial setup and migration, the daily workflow is simply:

```
Any thought → retain(content, bank_id)

Structured thought → /second-brain capture → guided template → retain

Document → create_documents(document_name, contents=[...])

Morning → /nudge (agent suggests when brain-clock.sh detects morning window)

Weekly → /review (agent suggests when brain-clock.sh detects Monday morning or Friday afternoon)
```

---

## 9. Onboarding Architecture

### Progressive Onboarding Timeline

Research shows progressive onboarding beats setup wizards. The skill detects a fresh brain (zero memories via `get_bank_stats`) and proactively guides users through stages:

| Stage | Timing | What Happens | Goal |
|-------|--------|-------------|------|
| Day 1 | First session | Normal conversation, system auto-retains (zero friction) | No setup burden; user sees the system "just works" |
| Day 2-3 | ~48 hours | "Magic moment" — surface "here's what I know about you so far" summary via `cross_bank_reflect` | Demonstrate value; user realizes the brain is already useful |
| Day 5-7 | ~1 week | First mental model synthesis — the processing ritual | Prevent abandonment; users who do a processing ritual in week 1 show 70%+ retention to month 3 |
| Week 2+ | Ongoing | Nudges and reviews become the daily/weekly habit | Sustainable habit loop |

### Discovery Interview (5 Questions)

The `/second-brain onboard` command (and the enhanced `/second-brain spark`) runs Jones' "Open Brain Spark" as a 5-question conversational discovery interview:

| # | Question | Purpose |
|---|----------|---------|
| 1 | "What tools do you use daily (especially which ones don't talk to each other)?" | Identify integration gaps — the pain points where a second brain adds most value |
| 2 | "What kind of decisions do you make repeatedly?" | Surface recurring decision patterns that benefit from persistent context |
| 3 | "What information do you find yourself re-explaining to AI?" | Find the "lost context" — the knowledge that should already be in long-term memory |
| 4 | "What do you forget that costs you time?" | Identify high-value capture targets (open loops, commitments, recurring tasks) |
| 5 | "Who do you work with regularly?" | Seed the entity graph with key people — enables relationship-aware nudges and reviews |

### Role-Tailored Output Categories

The discovery interview answers are used to classify the user's primary role. The "First 20 Captures" list uses role-specific categories:

| Role | Category 1 | Category 2 | Category 3 | Category 4 |
|------|-----------|-----------|-----------|-----------|
| Product manager | Stakeholder & Context | Decision Context | Customer & Market | Open Questions |
| Engineer | System Knowledge | Architecture & Design | Debugging & Incidents | Technical Debt |
| Writer | Voice & Style | Audience | Idea Development | Editorial Feedback Patterns |
| General / Mixed | People & Context | Projects & Decisions | Ideas & Insights | Open Loops |

### "Magic Moment" Design

The magic moment is the first time the brain demonstrates it knows something useful. It is triggered automatically on Day 2-3 (or immediately at the end of `/second-brain onboard`):

```
Step 1: Verify sufficient memories exist
  mcp__hindsight__get_bank_stats(bank_id="personal")
  → If total_memories < 5: skip magic moment, suggest more captures first

Step 2: Synthesize what the brain knows
  mcp__hindsight__cross_bank_reflect(
    query="Based on everything I've captured so far, what do you know about me? What patterns do you see? What should I capture next? Include at least one non-obvious inference — something I didn't explicitly state but that emerges from the patterns.",
    bank_ids=["personal", "work"],
    budget="mid"
  )
  → If cross_bank_reflect unavailable:
    mcp__hindsight__reflect(
      query="<same query>",
      bank_id="personal",
      budget="mid"
    )

Step 3: Present synthesis
  "Here's what your Second Brain knows about you so far: [reflect output]"

Step 4: Create the "Who I am" mental model
  mcp__hindsight__create_mental_model(
    bank_id="personal",
    name="Who I am",
    description="What are the key facts about this person — their role, tools, decision patterns, key relationships, and current priorities?"
  )
  mcp__hindsight__refresh_mental_model(bank_id="personal", model_id="<returned model_id>")

Step 5: Present
  "I've created your first mental model: 'Who I am'. This will get richer with every capture."
```

### `/second-brain onboard` Full Workflow

The full workflow with explicit MCP calls is documented in the Command Workflows section (Section 3, `/second-brain onboard`). The summary:

```
Step 1: mcp__hindsight__get_bank_stats(bank_id="personal")
        → If total_memories == 0: proceed; if >= 20: redirect to /spark

Step 2: mcp__hindsight__list_banks() → create missing banks via mcp__hindsight__create_bank()

Step 3: Discovery interview — 5 questions, conversational, no MCP calls

Step 4: mcp__hindsight__retain() for each substantive discovery answer
        → Route to "personal" or "work" bank based on content

Step 5: mcp__hindsight__cross_bank_reflect() with role-tailored prompt and response_schema
        → Generates "First 20 Captures" list
        → Falls back to mcp__hindsight__reflect() if cross-bank unavailable

Step 6: mcp__hindsight__retain() for each of the 3-5 captures the user selects

Step 7: mcp__hindsight__create_mental_model(bank_id="personal", name="Who I am", ...)
        mcp__hindsight__refresh_mental_model(bank_id="personal", model_id=<id>)
        mcp__hindsight__get_mental_model(bank_id="personal", model_id=<id>)
        → Present "Here's what your Second Brain knows about you"

Step 8: Summary — "Your Second Brain is alive. Run /nudge tomorrow morning."
```

### Cold Start Mitigation

| Strategy | Implementation |
|----------|---------------|
| Zero decisions at capture time | `retain` handles all classification automatically — user never chooses a category |
| Never ask users to organize | Entity extraction and knowledge graph linking are automatic; no manual tagging required |
| Show value within 15 minutes | Onboarding flow targets 5-min interview + 5-min guided captures + 5-min magic moment |
| Perspective diversity (anti-sycophancy) | MIT research warning: avoid telling users only what they want to hear in cold-start personalization. The magic moment should include at least one observation the user did not explicitly state — an inference or pattern, not just a recap of their words. Directives should instruct reflect to "surface non-obvious patterns and respectful challenges, not just confirmations." |

---

## 10. Skill File Structure

The skill lives at `.claude/skills/second-brain/` in any project that has Hindsight MCP configured.

```
.claude/skills/second-brain/
├── SKILL.md                           # Core workflow (1,500-2,000 words)
├── references/
│   ├── jones-building-blocks.md       # Jones mapping + Hindsight analogues (detailed)
│   ├── capture-templates.md           # Five Quick Capture templates with field schemas
│   ├── nudge-prompts.md               # Daily/weekly reflect queries + response schemas
│   ├── setup-guide.md                 # Bank creation, mental model setup, directive config
│   └── onboarding-flow.md            # Progressive onboarding timeline, discovery questions, role categories
└── scripts/
    ├── brain-stats.sh                 # Quick stats via MCP (optional, for power users)
    └── brain-clock.sh                 # Temporal context for time-aware nudge suggestions
```

### SKILL.md Frontmatter

```yaml
---
name: second-brain
description: This skill should be used when the user says "/second-brain", "/nudge", "/weekly-review", "/spark", "/capture", "/migrate", "/onboard", "set up my second brain", "daily digest", "weekly review", "what should I do today", "open loops", "what happened this week", "import my notes", "get started with second brain", or mentions wanting to use Hindsight as a Second Brain.
version: 0.1.0
---
```

### Content Distribution

| File | Content | Word Target |
|------|---------|------------|
| `SKILL.md` | Command overview, quick reference table, core workflows for nudge/review, bank defaults, resource pointers | 1,800 words |
| `references/jones-building-blocks.md` | Full Jones mapping with code examples, comparison tables | 2,500 words |
| `references/capture-templates.md` | Five templates with field schemas, example captures | 1,500 words |
| `references/nudge-prompts.md` | Full response schemas, example outputs, scheduling instructions | 2,000 words |
| `references/setup-guide.md` | Bank creation guide, mental model setup, directive config, correction workflow, scheduling | 2,500 words |
| `references/onboarding-flow.md` | Progressive onboarding timeline, discovery questions, role-tailored categories, magic moment design | 2,000 words |
| `scripts/brain-stats.sh` | Shell script wrapping MCP calls for quick terminal stats | ~50 lines |
| `scripts/brain-clock.sh` | Temporal context script — outputs date, day, hour, nudge/review windows | ~40 lines |

---

## 11. Implementation Phases

### Phase 1: Core Skill Files (Week 1)

**Goal:** Working skill that delivers `/nudge` and `/weekly-review` to a user with an existing single Hindsight bank.

**Deliverables:**
- `SKILL.md` with complete command table, nudge/review workflows, and resource pointers
- `references/nudge-prompts.md` with complete response schemas and example formatted output
- `references/setup-guide.md` with single-bank setup walkthrough

**Acceptance criteria:**
- A user with `bank_id="personal"` can run `/second-brain nudge` and receive a formatted daily digest under 150 words
- A user can run `/second-brain review` and receive a weekly review under 250 words
- Both commands degrade to single-bank `reflect` when cross-bank tools are unavailable

**Test approach:** Manual testing with a real Hindsight instance (localhost:8888). Run `/nudge` and inspect output format against the response schema.

**Risk:** If the bank has few memories, the reflect response may be sparse. Mitigation: test with a seeded bank; document minimum viable memory count (~10 facts) in setup guide.

### Phase 2: Setup and Capture (Week 1-2)

**Goal:** Zero-to-operational flow for new users. A user with no Hindsight history can run `/second-brain setup` and `/second-brain capture` to get started.

**Deliverables:**
- `/second-brain setup` workflow in `SKILL.md`
- `references/capture-templates.md` with five templates
- Mental model and directive creation calls documented

**Acceptance criteria:**
- A fresh Hindsight instance can be configured via `/second-brain setup` without manual Hindsight API calls
- `/second-brain capture` completes in under 3 turns for any of the five template types
- Standard mental models and directives are created and visible via `list_mental_models` / `list_directives`

**Test approach:** Create a new Hindsight bank, run `/second-brain setup`, verify bank stats and model list.

### Phase 3: Migration Workflows (Week 2)

**Goal:** Existing knowledge can be imported from AI sessions and external tools.

**Deliverables:**
- `/second-brain migrate` workflow documented and tested
- `/second-brain import` workflow with chunking strategy for Notion/Obsidian
- Import troubleshooting section in `references/setup-guide.md`

**Acceptance criteria:**
- A 10-message AI conversation can be migrated to Hindsight in one `/migrate` invocation
- A 50-note Obsidian vault can be imported via `/import` using `create_documents`
- Post-import `list_documents` shows correct document count

**Test approach:** Use a real Obsidian export (sanitized). Verify document records and spot-check extracted facts.

### Phase 4: Jones Building Blocks Reference (Week 2-3)

**Goal:** Complete reference documentation mapping Jones to Hindsight. This is the marketing-adjacent material that positions Hindsight as the canonical Second Brain backend.

**Deliverables:**
- `references/jones-building-blocks.md` with complete mapping, code examples, comparison tables

**Acceptance criteria:**
- Document covers all eight building blocks
- Each block includes: Jones description, Hindsight implementation, code example, known gaps
- Document is accurate to Hindsight's actual MCP API surface

**Test approach:** Cross-reference against the Hindsight MCP tool list. Every MCP tool call in the document must be verified against the actual tool signatures.

### Phase 5: Onboarding and Time-Awareness (Week 3)

**Goal:** Progressive onboarding flow that gets new users to their "magic moment" within 15 minutes. Time-aware nudge suggestions via `brain-clock.sh`.

**Deliverables:**
- `/second-brain onboard` workflow: discovery interview, role detection, guided captures, magic moment
- `references/onboarding-flow.md` with progressive timeline, discovery questions, role categories
- `scripts/brain-clock.sh` for temporal context (nudge/review window detection)

**Acceptance criteria:**
- Discovery interview completes in under 5 minutes (5 questions, conversational)
- Role-tailored "First 20 Captures" list generated with correct categories for detected role
- First mental model synthesis ("magic moment") within 15 minutes of starting onboard
- `brain-clock.sh` correctly detects morning, evening, weekly review, and monthly review windows
- Onboarding detects existing brains (>=20 memories) and redirects to `/spark`
- Anti-sycophancy: magic moment includes at least one non-obvious inference, not just recaps

**Test approach:** Fresh Hindsight instance. Run `/onboard`, time the flow, verify captures and mental model creation. Run `brain-clock.sh` at different times to verify window detection.

### Phase 6: `/spark` and `/status` (Week 3-4)

**Goal:** Complete the command surface with the remaining two commands.

**Deliverables:**
- `/second-brain spark` workflow (Spark Schema + capture flow)
- `/second-brain status` workflow (data retrieval, no LLM)

**Acceptance criteria:**
- `/spark` returns 15-20 personalized capture suggestions with categories
- `/status` returns memory counts per bank without an LLM call
- Both commands work with single-bank configuration

---

## 12. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Hindsight bank has too few memories for useful nudge | High (new users) | Medium | Document minimum viable count; `/setup` seeds initial context via `/migrate` |
| `cross_bank_reflect` unavailable (single-bank install) | Medium | Low | All commands degrade gracefully to single-bank `reflect` |
| Response schema enforces word limits but LLM ignores them | Medium | Low | Schema includes `total_word_count` field; skill post-processes to trim if needed |
| `/import` chunking loses intra-document context | Medium | Medium | Chunk at semantic boundaries (H2), not arbitrary word count; use `document_name` for grouping |
| Jones' building block terminology creates user confusion | Low | Medium | `references/jones-building-blocks.md` provides plain-language equivalents alongside Jones vocabulary |
| Time-aware nudges require session start to trigger | Medium | Low | `brain-clock.sh` runs at session start; user can also invoke `/nudge` manually at any time |
| `refresh_mental_model` during `/review` adds latency | Low | Low | Run refresh asynchronously; document that models update in background |
| Cold-start sycophancy in onboarding | Medium | High | MIT research warning: magic moment must include non-obvious inferences, not just recaps; directive instructs reflect to surface challenges, not just confirmations |
| Onboarding role detection misclassifies user | Medium | Low | Default to "General / Mixed" categories; user can re-run `/onboard` to correct |
| User opens session outside nudge windows | Low | Low | Agent can still offer `/nudge` on request; time-awareness is advisory, not mandatory |

---

## 13. Success Metrics

| Metric | Target | How to Measure |
|--------|--------|---------------|
| Time from install to first nudge | < 10 minutes | Manual stopwatch during setup testing |
| Daily digest word count | < 150 words consistently | Automated check of response schema `total_word_count` |
| Weekly review word count | < 250 words consistently | Automated check of response schema `total_word_count` |
| Commands work with single bank | 100% of commands degrade gracefully | Test suite: each command against single-bank install |
| Migration accuracy (AI session) | > 80% of migrated memories are accurate/useful | Manual review of 20 migrated sessions |
| Setup time (fresh install) | < 5 minutes end-to-end | Manual stopwatch |
| Onboarding to "magic moment" | < 15 minutes | Manual stopwatch during onboard flow |
| Onboarding discovery interview | < 5 minutes (5 questions) | Manual stopwatch |
| Week 1 processing ritual completion | > 70% of onboarded users | Track via mental model creation timestamp vs first retain timestamp |

---

## Appendix A: Time-Awareness Reference (`brain-clock.sh`)

The skill uses a simple bash script to make the agent time-aware. At session start, the agent runs `brain-clock.sh` and uses the output to decide whether to proactively suggest nudges or reviews. No OS-level scheduling, no launchd, no crontab — just temporal context that the agent interprets.

### `scripts/brain-clock.sh`

```bash
#!/bin/bash
# brain-clock.sh — Temporal context for Second Brain nudges
# Run: bash .claude/skills/second-brain/scripts/brain-clock.sh

HOUR=$(date +%H)
DAY=$(date +%A)
DATE=$(date +%Y-%m-%d)
MONTH_DAY=$(date +%d)

echo "date: $DATE"
echo "day: $DAY"
echo "hour: $HOUR"

# Morning window (7-10am) — ideal for daily nudge
if [ "$HOUR" -ge 7 ] && [ "$HOUR" -le 10 ]; then
  echo "nudge_window: morning"
  echo "daily_nudge: recommended"
fi

# Evening window (5-7pm) — ideal for end-of-day reflection
if [ "$HOUR" -ge 17 ] && [ "$HOUR" -le 19 ]; then
  echo "nudge_window: evening"
  echo "daily_nudge: optional"
fi

# Weekly review windows
if [ "$DAY" = "Monday" ] && [ "$HOUR" -ge 8 ] && [ "$HOUR" -le 11 ]; then
  echo "weekly_review: recommended (Monday morning)"
elif [ "$DAY" = "Friday" ] && [ "$HOUR" -ge 15 ] && [ "$HOUR" -le 18 ]; then
  echo "weekly_review: recommended (Friday afternoon)"
fi

# Month-end review
if [ "$MONTH_DAY" -ge 28 ]; then
  echo "monthly_review: approaching"
fi
```

### How the Agent Uses It

The SKILL.md instructs the agent:

1. At session start, run `bash .claude/skills/second-brain/scripts/brain-clock.sh` to get temporal context
2. If `daily_nudge: recommended`, proactively offer: "Good morning! Want your daily digest? /nudge"
3. If `weekly_review: recommended`, proactively offer: "It's [Monday/Friday] -- want your weekly review? /review"
4. If `monthly_review: approaching`, suggest a deeper mental model review
5. This is purely advisory — the agent suggests, the user decides

### Why This Approach

| Concern | How `brain-clock.sh` Addresses It |
|---------|-----------------------------------|
| Portability | Works with any MCP client, any OS — just a bash script |
| No OS-level setup | No launchd plists, no crontab entries, no permissions issues |
| User control | Agent suggests, user decides — no automated actions |
| Customizable | Users can edit the script to change time windows, add timezone logic, or add custom triggers |
| Stateless | No state files, no databases — reads system clock only |

### Customization Examples

Users can modify `brain-clock.sh` for their needs:

```bash
# Add timezone awareness
TZ_HOUR=$(TZ="America/New_York" date +%H)

# Add weekend detection (skip nudges on weekends)
if [ "$DAY" = "Saturday" ] || [ "$DAY" = "Sunday" ]; then
  echo "weekend: true"
  echo "daily_nudge: skip"
fi

# Add focus mode (no nudges during deep work hours)
if [ "$HOUR" -ge 10 ] && [ "$HOUR" -le 12 ]; then
  echo "focus_mode: active"
  echo "daily_nudge: defer"
fi
```

---

## Appendix B: Hindsight MCP Tool Reference for Skill Authors

Complete mapping of MCP tools used by the Second Brain skill:

| Tool | Used By | Parameters |
|------|---------|-----------|
| `retain` | `/capture`, `/migrate` | `content`, `context`, `tags`, `bank_id` |
| `create_documents` | `/import` | `bank_id`, `document_name`, `contents[]` |
| `recall` | (internal to reflect) | `query`, `bank_id`, `budget` |
| `reflect` | Single-bank fallback | `query`, `bank_id`, `budget`, `response_schema` |
| `cross_bank_reflect` | `/nudge`, `/review`, `/spark` | `query`, `bank_ids`, `budget`, `response_schema`, `include_reasoning_chain` |
| `cross_bank_recall` | (optional for `/status`) | `query`, `bank_ids` |
| `list_banks` | `/setup`, `/status` | — |
| `create_bank` | `/setup` | `bank_id`, `name`, `background`, `tags` |
| `get_bank` | `/status` | `bank_id` |
| `get_bank_stats` | `/status` | `bank_id` |
| `update_bank` | (user-driven) | `bank_id`, `name`, `background`, `tags` |
| `list_mental_models` | `/setup`, `/status` | `bank_id` |
| `create_mental_model` | `/setup` | `bank_id`, `name`, `source_query`, `tags` |
| `refresh_mental_model` | `/review` | `bank_id`, `mental_model_id` |
| `list_directives` | `/setup` | `bank_id` |
| `create_directive` | `/setup` | `bank_id`, `name`, `description` |
| `list_memories` | `/status` | `bank_id`, `limit`, `types`, `tags` |
| `get_memory` | (debugging) | `bank_id`, `memory_id` |
| `delete_memory` | (correction workflow) | `bank_id`, `memory_id` |
| `list_documents` | Post-import verification | `bank_id` |
| `list_operations` | `/status` (receipt view) | `bank_id`, `status` |
| `list_tags` | (optional) | `bank_id` |
