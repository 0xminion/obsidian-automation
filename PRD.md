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
- No transcript extraction for YouTube videos or podcasts
- Config files (dashboard, tag-registry, wiki-index) require manual updates

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
11. Add universal transcript extraction for YouTube and podcasts
12. Auto-update config files after ingest (dashboard, tag-registry, wiki-index)

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

**Solution:** Shared library at `lib/common.sh` sourced by all scripts.

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
- Entry.md documents all 4 template variants ✓
- Lint validates sections based on template field (check 7: template section validation) ✓
- Prompt templates support all variants ✓

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
- Dashboard shows all metrics in markdown tables ✓
- Run standalone or after compile ✓
- Output at `06-Config/dashboard.md` ✓

### R8: Externalize Prompts

**Problem:** Prompt templates are inline shell variables buried in scripts.

**Solution:** Move to `prompts/*.prompt` files:
- `common-instructions.prompt`
- `entry-structure.prompt`
- `concept-structure.prompt`
- `moc-structure.prompt`
- `compile-pass.prompt`
- `query-vault.prompt`
- `review-enrich.prompt`
- `review-update.prompt`

**Acceptance Criteria:**
- Scripts load prompts from files via `load_prompt()`, not inline variables ✓
- Prompts can be edited independently of scripts ✓
- Common library has `load_prompt()` helper ✓
- 8 prompt files: common-instructions, entry-structure, concept-structure, moc-structure, compile-pass, query-vault, review-enrich, review-update ✓

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

### R11: Universal Transcript Extraction

**Problem:** No automated way to extract transcripts from YouTube videos or podcast episodes. Manual transcription is time-consuming and inconsistent.

**Solution:** Implement intelligent fallback chains for transcript extraction:
- **YouTube:** existing transcript → TranscriptAPI (primary) → Supadata (fallback) → local Whisper (last resort)
- **Podcasts:** existing transcript → AssemblyAI (fallback)
- Cache transcripts for 30 days to avoid redundant API calls
- Output in markdown with metadata, timestamps, and speaker labels

**Acceptance Criteria:**
- `extract-transcript.sh` script supports both YouTube and podcast extraction
- `process-inbox.sh` automatically detects YouTube URLs and podcast files
- Transcripts cached at `~/.hermes/cache/transcripts/` with 30-day expiry
- YouTube fallback chain: TranscriptAPI → Supadata → Whisper
- Podcast fallback: check existing → AssemblyAI
- Markdown output with proper frontmatter for Obsidian integration

### R12: Post-Ingest Auto-Updates

**Problem:** Config files (dashboard.md, tag-registry.md, wiki-index.md) require manual updates and quickly become stale.

**Solution:** Automatically update config files after each ingest run:
- `dashboard.md` — regenerated after every ingest
- `tag-registry.md` — rebuilt with actual tag usage counts
- `wiki-index.md` — full rebuild if ≥5 notes processed (avoids overhead on small runs)

**Acceptance Criteria:**
- `process-inbox.sh` calls `vault-stats.sh` after processing
- `process-inbox.sh` calls `update-tag-registry.sh` after processing
- `process-inbox.sh` calls `reindex.sh` if ≥5 notes processed
- New `update-tag-registry.sh` script scans all notes and rebuilds tag registry
- Config files stay in sync without manual intervention

## Technical Architecture

### Scripts Reference

| Script | Purpose | Status |
|---|---|---|
| `process-inbox.sh` | Ingest: Source → Entry → Concepts → MoCs. Supports `--interactive` flag. Auto-updates dashboard, tag-registry, wiki-index | v2.2 |
| `review-pass.sh` | Review processed entries: `--untouched`, `--last N`, `--topic TAG`, `--entry NAME`, `--interactive` | v2.2 |
| `compile-pass.sh` | Cross-link, concept convergence, MoC rebuild, index rebuild, typed edges, schema review | v2.2 |
| `query-vault.sh` | Q&A with compound-back: answers expand wiki + update existing pages | v2.2 |
| `lint-vault.sh` | 10 health checks: orphans, unreviewed, stale, broken links, empty, template sections, drift, edges | v2.2 |
| `vault-stats.sh` | Dashboard: vault size, growth, review status, health indicators | v2.2 |
| `reindex.sh` | Full rebuild of wiki-index.md from scratch | v2.2 |
| `setup-git-hooks.sh` | Install git hooks for auto-commit and WIP protection | v2.2 |
| `update-tag-registry.sh` | Rebuild tag-registry.md with actual tag usage counts from all notes | v2.2 |
| `extract-transcript.sh` | Standalone transcript extraction for YouTube and podcasts | v2.2 |

### File Structure (v2.2)
```
├── lib/
│   ├── common.sh              # shared functions
│   ├── extract.sh             # content extraction (defuddle, liteparse, tavily)
│   └── transcribe.sh          # transcription abstraction (AssemblyAI + local whisper)
├── prompts/                   # externalized prompts
│   ├── common-instructions.prompt
│   ├── entry-structure.prompt
│   ├── concept-structure.prompt
│   ├── moc-structure.prompt
│   ├── compile-pass.prompt
│   ├── query-vault.prompt
│   ├── review-enrich.prompt
│   ├── review-update.prompt
│   └── podcast-structure.prompt
├── scripts/
│   ├── process-inbox.sh       # ingest with --interactive, auto-updates config
│   ├── review-pass.sh         # interactive entry review
│   ├── compile-pass.sh        # cross-links, edges, schema review
│   ├── query-vault.sh         # Q&A with compound-back
│   ├── lint-vault.sh          # 10 health checks
│   ├── vault-stats.sh         # dashboard generation
│   ├── reindex.sh             # full index rebuild
│   ├── setup-git-hooks.sh     # git initialization + hooks
│   ├── update-tag-registry.sh # tag registry rebuild
│   ├── extract-transcript.sh  # standalone transcript extraction
│   └── migrate-vault.sh       # optional: adopt existing vaults into v2 format
├── templates/
│   ├── Entry.md
│   ├── agents.md
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
├── v1/                        # archived v1 scripts, skills, templates
├── PRD.md
└── README.md
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
         ← transcribe.sh
         ← update-tag-registry.sh
         ← extract-transcript.sh

transcribe.sh ← process-inbox.sh (podcast processing)
             ← extract-transcript.sh

extract.sh ← process-inbox.sh (content extraction)

prompts/*.prompt ← process-inbox.sh (via load_prompt)
                  ← compile-pass.sh (via load_prompt)
                  ← query-vault.sh (via load_prompt)
                  ← review-pass.sh (via load_prompt)

load_prompt() ← all scripts that use externalized prompts

# Post-ingest auto-updates (baked into process-inbox.sh)
process-inbox.sh → vault-stats.sh (if processed > 0)
                → update-tag-registry.sh (if processed > 0)
                → reindex.sh (if processed >= 5)
```

## Migration from v2.1 to v2.2

1. Copy new files: `lib/common.sh`, `lib/extract.sh`, `prompts/*.prompt`, new scripts
2. Replace existing scripts with v2.2 versions
3. Add `reviewed: null` and `review_notes: null` to existing Entry frontmatter (run reindex.sh)
4. Add `template: standard` to existing Entry frontmatter (optional, defaults to standard)
5. Initialize `edges.tsv` (done automatically by setup_directory_structure)
6. Run `setup-git-hooks.sh` if vault isn't git-tracked
7. Copy new scripts: `update-tag-registry.sh`, `extract-transcript.sh`
8. No breaking changes — v2.1 vaults work without modification

**New in v2.2:**
- Config files (dashboard, tag-registry, wiki-index) now auto-update after ingest
- YouTube URLs and podcast files in inbox are automatically transcribed
- Transcript extraction available via `extract-transcript.sh` for standalone use

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
| Phase 8 | Transcript extraction system (YouTube + podcasts) | Done |
| Phase 9 | Post-ingest auto-updates (dashboard, tag-registry, wiki-index) | Done |
