# PRD: obsidian-automation v2.2

## Executive Summary

v2.2 upgrades the obsidian-automation wiki system from a batch-processing pipeline to a collaborative knowledge platform. The key theme: **the wiki is a conversation, not just a cron job.**

Ten recommendations address gaps in Karpathy's canonical pattern, improve code quality, add human-in-the-loop review, typed knowledge relationships, and operational tooling.

## Problem Statement

v2.1 implements all of Karpathy's checklist items but has issues:
- Code duplication across scripts (~150 lines of `run_with_retry` copy-pasted)
- No interactive review — batch-only processing removes the human from the loop
- Rigid ELI5 template forced on every Entry regardless of domain
- No typed relationships between notes (plain wikilinks only)
- Query answers don't compound back into existing pages
- No vault health dashboard or full reindex capability
- Inline prompt templates buried in shell scripts
- Schema (agents.md) doesn't co-evolve with the wiki

## Goals

1. Add human-in-the-loop review capability
2. Make queries compound back into the wiki
3. Eliminate code duplication across scripts
4. Support domain-adaptive Entry templates
5. Add typed edges for knowledge graph relationships
6. Automate git version control
7. Provide operational visibility (stats, reindex)
8. Externalize prompts for maintainability
9. Enable schema co-evolution
10. Maintain backward compatibility with v2.1 vaults

## Non-Goals

- RAG/vector search (wiki-index.md remains the retrieval layer)
- Multi-user collaboration (single-user for now)
- Web UI (Obsidian remains the viewer)
- Real-time sync (batch operations only)

## Recommendations

### R1: Interactive Ingestion + Review Pass

**Problem:** Batch processing removes the human from the loop. Karpathy's design is conversational.

**Solution:**
- `--interactive` flag on `process-inbox.sh` — pauses after each source for human feedback
- New `review-pass.sh` script — lets you discuss processed entries anytime
- New frontmatter fields: `reviewed:`, `review_notes:`
- `reviewed: null` = unreviewed inbox; `reviewed: 2026-04-14` = human-validated

**Acceptance Criteria:**
- `--interactive` pauses with summary after each source, accepts g/s/q responses
- `review-pass.sh --untouched` lists all unreviewed entries
- `review-pass.sh --interactive` shows each entry and accepts enrich/update/skip
- Lint reports unreviewed entry count

### R2: Query Compound-Back

**Problem:** Query-vault.sh creates standalone answer entries but doesn't update existing pages with discovered connections.

**Solution:** After creating the answer Entry, LLM also:
- Updates existing entries' Open questions or Linked concepts
- Adds reciprocal wikilinks to related notes
- Adds typed edges for new relationships

**Acceptance Criteria:**
- Query prompt includes mandatory compound-back step (Step 7)
- Log entry records which existing notes were updated
- Edges.tsv gets new entries for query-discovered relationships

### R3: Extract lib/common.sh

**Problem:** `run_with_retry()`, `log()`, lock management copy-pasted across 3+ scripts.

**Solution:** Shared library at `v2/lib/common.sh` sourced by all scripts.

**Acceptance Criteria:**
- All scripts source `lib/common.sh` — no duplicated functions
- `run_with_retry()`, `log()`, `acquire_lock()`, `register_url_source()`, `append_log_md()`, `auto_commit()`, `add_edge()` all in common.sh
- Scripts are smaller and focused on their unique logic

### R4: Domain-Adaptive Entry Templates

**Problem:** ELI5 forced on every Entry. Lint flags missing ELI5 as errors.

**Solution:**
- `template:` frontmatter field selects: `standard`, `technical`, `comparison`, `procedural`
- Each template has appropriate sections
- Lint checks sections based on template type

**Acceptance Criteria:**
- Entry.md documents all 4 template variants
- Lint validates sections based on template field
- Prompt templates support all variants

### R5: Typed Edges

**Problem:** Plain wikilinks don't express relationship types. At 100+ notes, typed relationships improve retrieval.

**Solution:**
- `06-Config/edges.tsv` — tab-separated: source, target, type, description
- Types: extends, contradicts, supports, supersedes, tested_by, depends_on, inspired_by
- Built during compile, added during queries and reviews

**Acceptance Criteria:**
- `edges.tsv` created during setup
- Compile pass builds edges from note relationships
- Query and review workflows add edges
- Lint checks edge consistency (references to non-existent notes)
- Common library has `add_edge()` and `get_edges()` helpers

### R6: Git Hooks for Auto-Commit

**Problem:** No version control on the vault. Changes are invisible.

**Solution:**
- `setup-git-hooks.sh` initializes git repo if needed
- Pre-commit hook blocks 07-WIP/ commits
- Auto-commit after ingest, compile, query, review, lint, reindex

**Acceptance Criteria:**
- `setup-git-hooks.sh` creates git repo and hooks
- Pre-commit hook rejects 07-WIP/ files
- All scripts call `auto_commit()` after operations

### R7: Vault Stats Dashboard

**Problem:** No visibility into vault growth, health, or review status.

**Solution:** `vault-stats.sh` generates `06-Config/dashboard.md` with:
- Vault size (entries, concepts, MoCs, sources)
- Growth (last 7 days)
- Review status (reviewed vs unreviewed)
- Health indicators (orphans, edges, last ingest)
- Recent activity from log.md

**Acceptance Criteria:**
- Dashboard shows all metrics in markdown tables
- Run standalone or after compile
- Output at `06-Config/dashboard.md`

### R8: Externalize Prompts

**Problem:** Prompt templates are inline shell variables buried in scripts.

**Solution:** Move to `v2/prompts/*.prompt` files:
- `common-instructions.prompt`
- `entry-structure.prompt`
- `concept-structure.prompt`
- `moc-structure.prompt`

**Acceptance Criteria:**
- Scripts load prompts from files, not inline variables
- Prompts can be edited independently of scripts
- Common library has `load_prompt()` helper

### R9: Full Reindex

**Problem:** No recovery mechanism when wiki-index.md drifts.

**Solution:** `reindex.sh` rebuilds index from scratch by scanning all notes.

**Acceptance Criteria:**
- Scans all Entry, Concept, MoC notes
- Extracts titles and summaries from frontmatter/first paragraph
- Rebuilds wiki-index.md with correct sections
- Logs and auto-commits

### R10: Schema Co-Evolution

**Problem:** agents.md is static. No mechanism to improve it based on experience.

**Solution:** Compile pass includes Operation 8 — schema review:
- Evaluates whether note structures still fit the content
- Suggests improvements to lint checks, workflows, templates
- Writes review to `Meta/Scripts/schema-review.md` for human approval
- Does NOT modify agents.md directly (human + LLM co-evolve)

**Acceptance Criteria:**
- Compile pass includes schema review operation
- Review written to `schema-review.md`
- agents.md documents the co-evolution workflow

## Technical Architecture

### File Structure (v2.2)
```
v2/
├── lib/
│   └── common.sh              # NEW: shared functions
├── prompts/                   # NEW: externalized prompts
│   ├── common-instructions.prompt
│   ├── entry-structure.prompt
│   ├── concept-structure.prompt
│   └── moc-structure.prompt
├── scripts/
│   ├── process-inbox.sh       # MODIFIED: sources common.sh, --interactive, externalized prompts
│   ├── review-pass.sh         # NEW: interactive entry review
│   ├── compile-pass.sh        # MODIFIED: sources common.sh, fixed dup bug, edges + schema review
│   ├── query-vault.sh         # MODIFIED: sources common.sh, compound-back
│   ├── lint-vault.sh          # MODIFIED: sources common.sh, template-aware, edges check
│   ├── vault-stats.sh         # NEW: dashboard generation
│   ├── reindex.sh             # NEW: full index rebuild
│   └── setup-git-hooks.sh     # NEW: git initialization + hooks
├── templates/
│   ├── Entry.md               # MODIFIED: reviewed/review_notes/template fields
│   ├── agents.md              # MODIFIED: review/edges/compound-back/co-evolution workflows
│   ├── Concept.md
│   ├── MoC.md
│   ├── Source.md
│   ├── Query.md
│   ├── wiki-index.md
│   ├── log.md
│   └── tag-registry.md
├── docs/
│   ├── Part1-Vault-Structure-Setup.md
│   └── Part2-Automation-Skills-Setup.md
└── README.md                  # MODIFIED: v2.2 documentation
```

### Dependency Graph
```
common.sh ← process-inbox.sh
         ← review-pass.sh
         ← compile-pass.sh
         ← query-vault.sh
         ← lint-vault.sh
         ← vault-stats.sh
         ← reindex.sh

prompts/*.prompt ← process-inbox.sh
                  ← compile-pass.sh (inline)
                  ← query-vault.sh (inline)
```

## Migration from v2.1 to v2.2

1. Copy new files: `lib/common.sh`, `prompts/*.prompt`, new scripts
2. Replace existing scripts with v2.2 versions
3. Add `reviewed: null` and `review_notes: null` to existing Entry frontmatter (run reindex.sh)
4. Add `template: standard` to existing Entry frontmatter (optional, defaults to standard)
5. Initialize `edges.tsv` (done automatically by setup_directory_structure)
6. Run `setup-git-hooks.sh` if vault isn't git-tracked
7. No breaking changes — v2.1 vaults work without modification

## Testing Strategy

- **Smoke test**: Run each script with an empty vault, verify no errors
- **Integration test**: Process a URL, review it, compile, query, lint — verify full pipeline
- **Regression test**: Compare v2.2 output with v2.1 for same inputs
- **Edge case test**: Duplicate URLs, empty files, missing directories, overlapping runs

## Timeline

| Phase | Deliverable | Estimate |
|---|---|---|
| Phase 1 | lib/common.sh + refactor scripts | Done |
| Phase 2 | review-pass.sh + Entry template variants | Done |
| Phase 3 | Query compound-back + typed edges | Done |
| Phase 4 | vault-stats.sh + reindex.sh | Done |
| Phase 5 | Git hooks + externalized prompts | Done |
| Phase 6 | Schema co-evolution + compile updates | Done |
| Phase 7 | README + docs + code review | Done |
