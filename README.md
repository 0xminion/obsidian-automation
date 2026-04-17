# v2.1.0: Obsidian AI-Automated PKM Vault — Karpathy-Style Wiki

Automated knowledge management system that turns raw web content, PDFs, and YouTube videos into a self-compiling wiki. Inspired by Andrej Karpathy's "LLM Knowledge Bases" approach.

## Vault Structure

```
01-Raw/              →  Drop URLs, PDFs, files here
02-Clippings/        →  Web clipper saves (already markdown)
03-Queries/          →  Drop .md files with questions for Q&A
04-Wiki/
├── sources/         ←  Full original content (not humanized)
├── entries/         ←  Entry notes (humanized, template-aware)
├── concepts/        ←  Shared vocabulary across sources (evergreen format)
└── mocs/            ←  Topic hubs with synthesized summaries
05-Outputs/
├── answers/         ←  Q&A responses (duplicate for quick access)
└── visualizations/  ←  Charts, diagrams, exports
06-Config/
├── wiki-index.md    ←  Auto-maintained TOC (retrieval layer)
├── url-index.tsv    ←  URL → entry mapping (dedup)
├── edges.tsv        ←  Typed relationships between notes
├── tag-registry.md  ←  Canonical tag list
├── log.md           ←  Structured activity log
└── agents.md        ←  Schema: tells any LLM agent how to maintain the wiki
07-WIP/              ←  Your drafts (untouched by automation)
08-Archive-Raw/      ←  Processed inbox items
09-Archive-Queries/  ←  Answered queries
```

## Note Structures

### Entries

English (template: standard):
```
## Summary
## Core insights        ← numbered list, key findings with evidence
## Other takeaways      ← continues numbering from Core insights
## Diagrams             ← optional — 'n/a' if not needed
## Open questions
## Linked concepts
```

Chinese (template: chinese, language: zh):
```
## 摘要
## 核心发现            ← 编号列表，关键发现和论点
## 其他要点            ← 继续从核心发现编号开始
## 图表               ← 可选 — 不需要则写 'n/a'
## 开放问题
## 关联概念
```

Other templates: `technical` (research papers), `comparison` (product comparisons), `procedural` (tutorials).

### Concepts (Evergreen Format)

Concepts are atomic notes — one idea per note, title IS the concept.

English:
```
Frontmatter: sources: ["[[source-note]]"]

## Core concept    ← single overview paragraph (2-3 sentences)
## Context         ← flowing prose (2-4 paragraphs): mechanism, significance, evidence, tensions
## Links           ← wikilinks to related notes
```

Chinese (language: zh):
```
Frontmatter: sources: ["[[source-note]]"]

## 核心概念        ← 一段概述 (2-3句)
## 背景            ← 连贯正文 (2-4段)：运作机制、为什么重要、实际案例、争议
## 关联            ← wikilinks
```

### MoCs (Maps of Content)

Topic hubs with synthesized summaries. Flexible section structure — organize by theme, language, or time period. Use `English / 中文` heading format when bridging languages.

## Scripts

| Script | Purpose |
|---|---|
| `process-inbox.sh` | Ingest: Source → Entry → Concepts → MoCs. Supports `--interactive` flag. Auto-updates dashboard, tag-registry, wiki-index |
| `review-pass.sh` | Review processed entries: `--untouched`, `--last N`, `--topic TAG`, `--entry NAME`, `--interactive` |
| `compile-pass.sh` | Cross-link, concept convergence, MoC rebuild, index rebuild, typed edges, schema review |
| `query-vault.sh` | Q&A with compound-back: answers expand wiki + update existing pages |
| `lint-vault.sh` | 12 health checks: orphans, unreviewed, stale, broken links, empty, concept structure, template sections, orphaned concepts, index drift, edges, stubs, tags |
| `vault-stats.sh` | Dashboard: vault size, growth, review status, health indicators |
| `reindex.sh` | Full rebuild of wiki-index.md from scratch |
| `setup-git-hooks.sh` | Install git hooks for auto-commit and WIP protection |
| `update-tag-registry.sh` | Rebuild tag-registry.md with actual tag usage counts from all notes |
| `extract-transcript.sh` | Standalone transcript extraction for YouTube and podcasts |
| `migrate-vault.sh` | Adopt existing Obsidian vaults into v2 format (scan/dry-run/execute) |

## Typed Edges (`edges.tsv`)

4-column tab-separated relationships between notes:

```
source<tab>target<tab>type<tab>description
```

Built automatically during compile-pass. Also added during queries and reviews.

## Extraction Chain

| Source Type | Chain |
|---|---|
| arxiv | `arxiv.org/html/IDv1` → defuddle → alphaxiv → liteparse |
| URLs | defuddle → liteparse → browser screenshot |
| X/Twitter | defuddle (primary) → liteparse → browser |
| YouTube | existing → TranscriptAPI → Supadata → whisper |
| Podcasts | existing → AssemblyAI → whisper |
| PDFs | liteparse → OCR |

## Critical Rules

1. NEVER touch `07-WIP/`
2. NEVER overwrite existing notes — use `check_collision()` + `resolve_collision()`
3. NO stubs/placeholder content — every section must have real content at creation
4. Tags must be topic-specific English (never platform names like x.com, tweet)
5. Chinese body text stays Chinese in all 04-Wiki notes
6. YAML wikilinks must be quoted: `source: "[[note]]"`
7. File names: Chinese titles → Chinese filenames, English titles → kebab-case
8. NEVER use URL slugs as filenames or titles

## Quick Start

```bash
# 1. Set up vault
mkdir -p ~/MyVault/{01-Raw,02-Clippings,03-Queries,04-Wiki/{sources,entries,concepts,mocs},05-Outputs/{answers,visualizations},06-Config,07-WIP,08-Archive-Raw,09-Archive-Queries,Meta/Scripts,Meta/Templates}

# 2. Copy scripts, lib, prompts, and templates
chmod +x scripts/*.sh
cp scripts/*.sh ~/MyVault/Meta/Scripts/
cp lib/common.sh ~/MyVault/Meta/Scripts/../lib/
cp -r prompts ~/MyVault/Meta/Scripts/../
cp templates/*.md ~/MyVault/Meta/Templates/

# 3. Set up git hooks (optional but recommended)
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/setup-git-hooks.sh

# 4. Process (batch mode)
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/process-inbox.sh

# 4b. Process (interactive — discuss each source)
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/process-inbox.sh --interactive

# 5. Review unreviewed entries
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/review-pass.sh --untouched --interactive

# 6. Compile (weekly)
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/compile-pass.sh

# 7. Query
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/query-vault.sh

# 8. Lint
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/lint-vault.sh

# 9. Stats
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/vault-stats.sh

# 10. Reindex (if index drift detected)
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/reindex.sh
```

## Recommended Workflow

```
Daily:    Drop sources in 01-Raw/, run process-inbox.sh
          → Auto-updates: dashboard.md, tag-registry.md, wiki-index.md (if ≥5 notes)
          Drop questions in 03-Queries/, run query-vault.sh

Weekly:   Run compile-pass.sh (cross-links, concept merge, edges, schema review)
          Run review-pass.sh --untouched (review key entries)
          Run lint-vault.sh (check health)

Monthly:  Run reindex.sh (if lint flags drift — not usually needed due to auto-rebuild)
          Review Meta/Scripts/schema-review.md (from compile)
```

## Shared Library (`lib/common.sh`)

All scripts source this. Provides:
- `log()` — structured logging
- `run_with_retry()` — exponential backoff, max 3 attempts
- `acquire_lock()` / `release_lock()` — prevents overlapping runs
- `source_exists_for_url()` / `register_url_source()` — URL dedup
- `setup_directory_structure()` — creates all vault directories
- `append_log_md()` — structured log.md entries
- `add_edge()` / `get_edges()` — typed relationship management
- `auto_commit()` — git auto-commit with structured messages
- `load_prompt()` — load prompt templates from `prompts/*.prompt` files
- `check_collision()` / `resolve_collision()` — prevent note overwrites
- `qmd_concept_search()` — semantic concept search via qmd + Qwen3-Embedding-0.6B-Q8
- `qmd_results_to_names()` — extract concept names from qmd results
- `qmd_batch_concept_search()` — batch semantic search for manifest entries

## v2 Pipeline (3-Stage Architecture)

The v2 pipeline (`process-inbox-v2.sh`) replaces the monolithic v1 with:
- **Stage 1** (`stage1-extract.sh`): Shell-only extraction. Routes URLs by type. No LLM.
- **Stage 2** (`stage2-plan.sh`): Semantic concept pre-search via qmd, then 1 planning agent.
- **Stage 3** (`stage3-create.sh`): Concept convergence search + N parallel write agents.

### Semantic Concept Search (qmd)

Concept matching uses [qmd](https://github.com/tobi/qmd) with **Qwen3-Embedding-0.6B-Q8** for semantic similarity instead of keyword grep.

Setup (one-time):
```bash
bash scripts/setup-qmd.sh
```

This installs qmd, downloads the 639MB embedding model, and indexes your concepts collection.

Manual commands:
```bash
# Index concepts (after adding new concept files)
qmd update

# Re-embed (after changing model)
qmd embed -f

# Test search
qmd query "prediction markets" --json -n 5 --min-score 0.3 -c concepts --no-rerank
```

The pipeline auto-detects qmd availability and falls back gracefully if not installed.

## Notes

- Scripts use `set -uo pipefail` (not `set -e`). Errors are handled explicitly via `|| result=$?` pattern. This is intentional — transient failures (API rate limits, file races) should retry, not abort.
- `setup-git-hooks.sh` intentionally does not source `lib/common.sh` — it runs during initial setup before the library exists.
- Lock files use `mkdir` (atomic on POSIX) instead of `touch` (TOCTOU race).
- `md5sum` has portable fallbacks: `md5 -q` (macOS) → `cksum` (any system).
- Tested with bash 4.4+. Run `shellcheck scripts/*.sh` for static analysis.
