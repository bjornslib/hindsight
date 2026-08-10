# Epic 5: Second Brain Skill — PRD Section

> **Insert into:** PRD-SECONDBRAIN-001.md, Section 8 (Epics), after Epic 3
>
> This file contains the standalone Epic 5 section. Do not modify PRD-SECONDBRAIN-001.md directly — copy the content below the horizontal rule into the PRD when ready.

---

### Epic 5: Second Brain Skill (Claude Code Skill)

**Status:** In Design (2026-03-16)

**Goal:** Deliver a portable Claude Code skill (`.claude/skills/second-brain/`) that implements Nate B Jones' eight building blocks using Hindsight MCP tools as the memory backend, making Hindsight the natural choice for Second Brain adopters.

---

#### What Will Be Done

A Claude Code skill shipped as a directory of markdown files and optional scripts. The skill:

1. **Maps Jones' vocabulary to Hindsight tools** — every building block has a named command and a documented Hindsight MCP equivalent so users moving from Jones' Notion+Zapier stack understand the analogue immediately.

2. **Implements Jones' five companion prompts** as slash commands backed by Hindsight MCP calls:
   - `/second-brain migrate` — Extract context from current AI sessions into Hindsight (`retain` batched)
   - `/second-brain import` — Import from Notion/Obsidian/Markdown via `create_documents`
   - `/second-brain spark` — Discover personalized use cases, generate "First 20 Captures" via `cross_bank_reflect` with structured output
   - `/second-brain capture` — Guided capture with Jones' five templates, backed by `retain`
   - `/second-brain review` — Weekly review synthesis via `cross_bank_reflect` with HIGH budget and `response_schema`
   - `/second-brain onboard` — Full progressive onboarding: discovery interview (5 questions), role-tailored "First 20 Captures", guided first captures, and first mental model synthesis as the "magic moment"

3. **Adds four additional commands** completing the Jones "Tap on the Shoulder" pattern:
   - `/second-brain nudge` (alias `/nudge`) — Daily digest: top 3 actions, open loops, one win. Under 150 words. Uses `cross_bank_reflect` with MID budget and structured `response_schema`.
   - `/second-brain status` (alias `/brain-status`) — Brain health dashboard: memory counts, entity counts, mental model list, last capture timestamp. No LLM call — pure data retrieval via `get_bank_stats`, `list_mental_models`, `list_memories`.
   - `/second-brain setup` — Zero-to-operational provisioning: creates standard banks, mental models (Personal context, Active projects, Key people, Open loops), and directives. Safe to re-run.
   - Time-aware nudging via `brain-clock.sh` — A shell script that outputs temporal context (date, hour, nudge windows). The agent runs this at session start and proactively suggests `/nudge` or `/review` when appropriate. No OS-level scheduling required.

4. **Provides response schemas** that enforce Jones' output specifications:
   - Nudge schema: 3 actions + 1 open loop + 1 win, <150 words total
   - Review schema: narrative + open loops + 3 next-week actions + 1 theme, <250 words total
   - Spark schema: 15-20 capture suggestions with category and rationale

5. **Degrades gracefully to single-bank operation** — every command that calls `cross_bank_reflect` falls back to single-bank `reflect` when only one bank exists, making the skill immediately useful after `/second-brain setup` with default configuration.

---

#### Key Design Decisions

| Decision | Choice | Rationale |
|---------|--------|-----------|
| Bank count | 2 default banks (`personal`, `work`), single-bank option available | Mirrors Jones' personal/professional split; single-bank lowers barrier to entry |
| Jones' four Notion tables | Not mirrored as four banks; entity types within banks provide the same isolation | Entity-type queries are faster and cheaper than cross-bank queries; person/project links are intra-bank |
| Time-awareness | `brain-clock.sh` provides temporal context; agent suggests nudges/reviews at appropriate times | Works with any MCP client, no OS-level setup, user always decides; simple bash script anyone can customize |
| Onboarding | Progressive onboarding (auto-detect fresh brain) over setup wizard | Research shows progressive onboarding beats wizards — users who complete a processing ritual in week 1 show 70%+ retention to month 3; zero decisions at capture time (Jones' core thesis) |
| Bouncer building block | Not implemented; documented as "use capture templates to improve input quality" | Bouncer requires a user review queue that does not yet exist (see Appendix C) |
| Reflection budget for review | HIGH (enables multi-step decomposition from Epic 3) | Weekly synthesis benefits from decomposition — "what happened this week?" → sub-questions per domain |

---

#### Acceptance Criteria

**Setup:**
- [ ] `/second-brain setup` creates standard banks, 4 mental models per bank, and 2 directives per bank from a fresh Hindsight instance in under 5 minutes
- [ ] Setup is idempotent — re-running does not create duplicates

**Daily Digest (Nudge):**
- [ ] `/second-brain nudge` returns a formatted daily digest in under 150 words
- [ ] Output contains exactly 3 actions, 1 open loop, and 1 win
- [ ] Command completes in under 10 seconds (MID budget, 2 banks)
- [ ] Command works with a single bank (no cross-bank tools required)

**Weekly Review:**
- [ ] `/second-brain review` returns a formatted weekly review in under 250 words
- [ ] Output contains a narrative, 1-4 open loops with urgency ratings, 3 next-week actions, and 1 theme
- [ ] Command completes in under 30 seconds (HIGH budget, 2 banks)
- [ ] "Active projects" and "Open loops" mental models are refreshed before generating the review

**Capture:**
- [ ] `/second-brain capture` completes in under 3 conversation turns for any of the five template types (person, project, idea, meeting, admin)
- [ ] Capture result is visible in `list_memories` immediately after

**Onboarding:**
- [ ] `/second-brain onboard` discovery interview completes in under 5 minutes (5 questions, conversational flow)
- [ ] Discovery output generates a role-tailored "First 20 Captures" list (categories differ by detected role: PM, engineer, writer, etc.)
- [ ] First mental model synthesis ("magic moment") is generated within 15 minutes of starting onboarding
- [ ] Automatic progressive onboarding detects a fresh brain (zero memories) and proactively guides the user through stages
- [ ] Onboarding avoids sycophancy in cold-start personalization — maintains perspective diversity (MIT research warning)
- [ ] User is guided through first 3-5 captures using role-appropriate templates before the "magic moment"

**Time-Awareness:**
- [ ] `scripts/brain-clock.sh` correctly outputs date, day, hour, and nudge/review window indicators
- [ ] Morning window (7-10am) outputs `daily_nudge: recommended`
- [ ] Evening window (5-7pm) outputs `daily_nudge: optional`
- [ ] Monday morning (8-11am) and Friday afternoon (3-6pm) output `weekly_review: recommended`
- [ ] Month-end (day >= 28) outputs `monthly_review: approaching`
- [ ] Agent proactively suggests `/nudge` or `/review` based on `brain-clock.sh` output at session start

**Migration:**
- [ ] `/second-brain migrate` extracts 5-20 candidate memories from a 10-message conversation in a single pass
- [ ] User can approve/reject individual items before retain is called
- [ ] `/second-brain import` successfully imports a 20-file Obsidian vault via `create_documents`; each file becomes a named document record

**Status:**
- [ ] `/second-brain status` returns memory counts per bank without making an LLM call
- [ ] Output includes: bank count, per-bank memory count, last capture timestamp

**Skill Structure:**
- [ ] `SKILL.md` is under 2,000 words
- [ ] All five reference files exist and are referenced from `SKILL.md`
- [ ] SKILL.md frontmatter includes all trigger phrases required to auto-load on user commands
- [ ] Skill works from `.claude/skills/second-brain/` in any project with Hindsight MCP configured

---

#### Technical Approach

```
User invokes /second-brain <command>
        |
        v
Skill loads SKILL.md (always in context when triggered)
Skill loads relevant references/ file (as needed)
        |
        v
Command-specific workflow:

  /nudge, /review, /spark:
    cross_bank_reflect(
      query=<command-specific query>,
      bank_ids=<brain banks by tag "second-brain">,
      budget=<mid|high>,
      response_schema=<command-specific schema>
    )
    → Format structured_output into Jones-spec output
    → Print to terminal

  /capture:
    Load capture-templates.md for template type
    Gather fields via conversation (max 3 turns)
    retain(structured content, bank_id, tags)

  /migrate:
    Reflect on current conversation context (no MCP call)
    Generate candidate memory list
    User approves → batch retain

  /import:
    Read source files
    Chunk at semantic boundaries
    create_documents(document_name, contents=[chunks])

  /setup:
    list_banks() → identify missing
    create_bank() for each missing standard bank
    create_mental_model() × 4 per bank
    create_directive() × 2 per bank

  /onboard:
    Detect fresh brain (get_bank_stats → zero memories)
    Run discovery interview (5 questions, conversational)
    Classify role from answers (PM, engineer, writer, etc.)
    Generate role-tailored "First 20 Captures" list
    Guide user through first 3-5 captures → retain each
    Generate first mental model synthesis → create_mental_model
    Present "magic moment" summary of what the brain now knows

  Time-awareness (brain-clock.sh):
    At session start: bash .claude/skills/second-brain/scripts/brain-clock.sh
    Parse output for nudge_window, daily_nudge, weekly_review, monthly_review
    If daily_nudge == "recommended": suggest /nudge
    If weekly_review == "recommended": suggest /review
    Agent suggests, user decides — no automated scheduling

  /status:
    get_bank_stats() per bank
    list_mental_models() per bank
    list_memories(limit=5) for last capture info
    Format as dashboard (no LLM)
```

**Dependency on Epics 2 and 3:**
- `/nudge` and `/review` use `cross_bank_reflect` (Epic 2) with `response_schema` (Epic 1)
- `/review` benefits from multi-step decomposition (Epic 3, HIGH budget) for richer synthesis
- All commands degrade to single-bank if Epic 2 cross-bank tools are unavailable

---

#### Files to Be Created

| File | Location | Description |
|------|----------|-------------|
| `SKILL.md` | `.claude/skills/second-brain/SKILL.md` | Core skill: command table, nudge/review workflows, bank defaults, resource pointers |
| `jones-building-blocks.md` | `.claude/skills/second-brain/references/` | Complete Jones→Hindsight mapping with code examples |
| `capture-templates.md` | `.claude/skills/second-brain/references/` | Five Quick Capture templates with field schemas and examples |
| `nudge-prompts.md` | `.claude/skills/second-brain/references/` | Response schemas, formatted output examples, scheduling instructions |
| `setup-guide.md` | `.claude/skills/second-brain/references/` | Bank creation guide, mental model setup, directive config, correction workflow, scheduling |
| `brain-stats.sh` | `.claude/skills/second-brain/scripts/` | Shell script for quick brain stats (optional) |
| `brain-clock.sh` | `.claude/skills/second-brain/scripts/` | Temporal context script for time-aware nudge/review suggestions |
| `onboarding-flow.md` | `.claude/skills/second-brain/references/` | Progressive onboarding timeline, discovery questions, role-tailored capture categories, magic moment design |

**Solution Design:** `docs/SD-EPIC5-SECOND-BRAIN-SKILL.md`

---

#### Success Metrics

| Metric | Target |
|--------|--------|
| Time from skill install to first nudge | < 10 minutes |
| Daily digest word count | < 150 words, consistently |
| Weekly review word count | < 250 words, consistently |
| Commands work with single bank | 100% of commands degrade gracefully |
| `/setup` time on fresh Hindsight instance | < 5 minutes end-to-end |
| Onboarding to "magic moment" | < 15 minutes |
| Week 1 retention (users who complete onboarding) | > 70% still active at month 3 |
