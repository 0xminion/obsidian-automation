# PRD: obsidian-automation v2.1.0

## Executive Summary

v2.1.0 is the self-contained Obsidian vault automation system that turns raw web content into a structured, interconnected wiki. Pipeline: Source → Entry → Concept → MoC. All automation baked into scripts, no external cron dependencies.

**Architecture:** 3-stage pipeline (Extract → Plan → Create) with parallel extraction, semantic concept search via qmd (Qwen3-Embedding-0.6B-Q8), and parallel write agents. 4-6x faster than the monolithic v1.

## Problem Statement

The system needs to:
1. Extract content from diverse sources (web, X/Twitter, YouTube, podcasts, PDFs, arxiv)
2. Structure it into atomic, evergreen notes with typed relationships
3. Support bilingual content (Chinese sources stay Chinese, English stays English)
4. Maintain vault health through automated linting and indexing
5. Be self-contained — run one script, everything updates

## Architecture

### 3-Stage Pipeline

```
01-Raw/ → process-inbox.sh → 04-Wiki/{sources, entries, concepts, mocs}
                                    ↓
                             Post-ingest auto-updates:
                             - dashboard.md
                             - tag-registry.md
                             - wiki-index.md (if ≥5 notes)
```

**Stage 1: Extract** (shell, no agent, ~10s for 16 URLs)
- Pure shell extraction using defuddle/transcriptapi/curl
- No LLM involved — deterministic, fast
- Parallel extraction via `xargs -P4` (configurable `EXTRACT_PARALLEL`)
- Output: `/tmp/extracted/{hash}.json` per URL

**Stage 2: Plan** (1 agent, semantic concept pre-search)
- Pre-searches existing concepts via qmd semantic embeddings (not grep)
- Single planning agent produces per-source creation plans
- Handles bilingual detection, template selection, tag suggestions
- Output: `/tmp/extracted/plans.json`

**Stage 3: Create** (N parallel agents)
- Parallel write agents (default 3, configurable `--parallel N`)
- Concept convergence uses pre-fetched qmd semantic matches
- Per-agent prompt: ~5K chars (vs ~18K in v1)
- Output validation via `validate-output.sh` runs automatically
- Output: Files written to vault, inbox archived, wiki-index updated

### Pipeline Flags

| Flag | Purpose |
|---|---|
| `--vault PATH` | Override VAULT_PATH |
| `--parallel N` | Number of parallel write agents (default: 3) |
| `--dry-run` | Preview pipeline without executing |
| `--review` | Run Stages 1+2, save plans to `07-WIP/plans-review.json` for manual review |
| `--resume` | Skip Stages 1+2, use reviewed plans from `--review` |

`--review` and `--resume` are mutually exclusive.

### Semantic Concept Search (qmd)

Concept matching uses [qmd](https://github.com/tobi/qmd) with **Qwen3-Embedding-0.6B-Q8** for semantic similarity instead of keyword grep.

- Search priority: daemon vector → CLI vector → BM25 (keyword fallback)
- Pipeline auto-detects qmd availability, falls back gracefully if not installed
- Setup via `setup-qmd.sh` (one-time: installs qmd, downloads 639MB model, indexes concepts)

### Note Structures

**Entries** — summarize a source with structured insights.

Template: standard (English):
- Summary → Core insights → Other takeaways → Diagrams (optional) → Open questions → Linked concepts

Template: chinese:
- 摘要 → 核心发现 → 其他要点 → 图表 (optional) → 开放问题 → 关联概念

Other templates: technical, comparison, procedural.

**Concepts** — atomic evergreen notes. One idea per note. Title IS the concept.

Format (both languages):
- Core concept / 核心概念 — single overview paragraph
- Context / 背景 — flowing prose (mechanism, significance, evidence, tensions)
- Links / 关联 — wikilinks to related notes
- Sources in frontmatter metadata

**MoCs** — topic hubs with synthesized summaries. Flexible section structure.

### Extraction Chain

| Source | Primary | Fallback |
|---|---|---|
| arxiv | HTML via defuddle | alphaxiv overview |
| URLs | defuddle | liteparse → browser |
| X/Twitter | defuddle | liteparse → browser |
| YouTube | TranscriptAPI | Supadata → whisper |
| Podcasts | AssemblyAI | whisper |
| PDFs | liteparse | OCR |

### Scripts

| Script | Purpose |
|---|---|
| `process-inbox.sh` | **Primary pipeline.** 3-stage: Extract → Plan → Create. Supports `--review`, `--resume`, `--parallel N`, `--dry-run` |
| `review-pass.sh` | Review entries: `--untouched`, `--last N`, `--topic TAG`, `--entry NAME`, `--interactive` |
| `compile-pass.sh` | Cross-linking, concept convergence, MoC rebuild, edges, schema review |
| `query-vault.sh` | Q&A with compound-back (answers update existing pages) |
| `lint-vault.sh` | 12 health checks (orphans, unreviewed, stale, broken links, empty, concept structure, template sections, orphaned concepts, index drift, edges, stubs, tags) |
| `vault-stats.sh` | Dashboard generation |
| `reindex.sh` | Full wiki-index.md rebuild |
| `setup-git-hooks.sh` | Git initialization + hooks |
| `update-tag-registry.sh` | Tag registry rebuild |
| `extract-transcript.sh` | Standalone transcript extraction |
| `migrate-vault.sh` | Adopt existing vaults (scan/dry-run/execute) |
| `validate-output.sh` | Validates pipeline output: frontmatter, sections, stubs, tags. Supports `--fix` |
| `setup-qmd.sh` | One-time setup for qmd semantic search |

### Key Design Decisions

1. **Evergreen concepts** — 3-section format (Core concept, Context, Links) instead of 6-section template. Atomic notes, one idea per note, flowing prose in Context.

2. **Flattened entry structures** — no nested ELI5/关键洞察 wrappers. Core insights and Other takeaways are top-level sections.

3. **Sources as frontmatter** — concept provenance stored in `sources: [...]` YAML field, not a body section. Cleaner body, machine-readable metadata.

4. **Optional diagrams** — only include if a diagram genuinely aids understanding. Write 'n/a' otherwise. Never forced.

5. **No stubs** — every section must have real content at creation. Lint enforces this.

6. **Topic-specific tags** — blocklist rejects platform names (x.com, tweet, http, url, link). Tags describe content, not source.

7. **4-column edges** — `source<tab>target<tab>type<tab>description` format for edges.tsv.

8. **Self-contained automation** — no external cron. Run process-inbox.sh, everything updates.

9. **Chinese stays Chinese** — all 04-Wiki body text for Chinese sources stays in Chinese. Only YAML keys, tags, and filenames use English.

10. **Defuddle primary** — removed tavily as extraction fallback. Defuddle is primary for all web content including X/Twitter.

11. **3-stage pipeline** — separates extraction (shell), planning (1 agent), and creation (N agents). Extraction never touches LLM. Planning is batched. Creation is parallelizable.

12. **Semantic concept search** — qmd with Qwen3-Embedding-0.6B-Q8 replaces keyword grep for concept matching. 130x faster than loading model per-query (daemon mode).

13. **Review/resume workflow** — `--review` pauses after planning for human inspection. `--resume` continues from reviewed plans. Enables human-in-the-loop without breaking automation.

## Acceptance Criteria

- [x] process-inbox.sh handles URLs, YouTube, podcasts, PDFs, arxiv
- [x] 3-stage pipeline: Extract (shell) → Plan (1 agent) → Create (N agents)
- [x] Semantic concept search via qmd + Qwen3-Embedding-0.6B-Q8
- [x] `--review` and `--resume` flags for human-in-the-loop
- [x] `--parallel N` flag for configurable agent concurrency
- [x] Entry templates: standard, chinese, technical, comparison, procedural
- [x] Concept notes use evergreen format (3 sections + frontmatter sources)
- [x] No stub/placeholder content allowed (lint enforced)
- [x] Tags validated against blocklist (lint enforced)
- [x] Edges use 4-column TSV format
- [x] Post-ingest auto-updates: dashboard, tag-registry, wiki-index
- [x] All scripts source lib/common.sh (no duplication)
- [x] Prompts externalized in prompts/*.prompt files
- [x] Collision detection prevents note overwrites
- [x] Git auto-commit after every operation
- [x] 12 lint checks covering all structural requirements
- [x] Output validation with `validate-output.sh --fix` auto-repair

## Non-Goals

- RAG/vector search (wiki-index.md remains the retrieval layer)
- Multi-user collaboration (single-user)
- Web UI (Obsidian remains the viewer)
- Real-time sync (batch operations only)

## Testing

- **Unit tests**: Function existence, JSON schema validation, parameter validation
- **Integration test**: Full pipeline end-to-end: Stage 1 → Stage 2 → Stage 3 with mocked agents
- **Lint validation**: All 12 checks pass against actual vault content
- **Edge cases**: Empty inbox, malformed URLs, collision detection, qmd fallback
