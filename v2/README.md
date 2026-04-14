# v2.2: Obsidian AI-Automated PKM Vault — Karpathy-Style Wiki

Automated knowledge management system that turns raw web content, PDFs, and YouTube videos into a self-compiling wiki. Inspired by Andrej Karpathy's "LLM Knowledge Bases" approach.

## What's New in v2.2

- **Review pass** (`review-pass.sh`) — discuss processed entries with the LLM, enrich them, mark reviewed
- **Query compound-back** — queries don't just create answer entries, they update existing wiki pages with discovered connections
- **Shared library** (`lib/common.sh`) — all scripts share retry logic, logging, lock management, URL dedup
- **Domain-adaptive templates** — Entry notes support `standard`, `technical`, `comparison`, `procedural` templates
- **Typed edges** (`edges.tsv`) — relationships between notes with types: extends, contradicts, supports, supersedes, tested_by, depends_on, inspired_by
- **Git auto-commit** — all operations auto-commit with structured messages
- **Vault stats** (`vault-stats.sh`) — dashboard showing growth, health, review status
- **Full reindex** (`reindex.sh`) — rebuild wiki-index.md from scratch (fsck for your wiki)
- **Externalized prompts** — prompt templates in `v2/prompts/*.prompt` files, no more inline heredocs
- **Schema co-evolution** — compile pass evaluates agents.md and suggests improvements

## Vault Structure

```
01-Raw/             →  Drop URLs, PDFs, files here
02-Clippings/        →  Web clipper saves (already markdown)
03-Queries/          →  Drop .md files with questions for Q&A
04-Wiki/
├── sources/         ←  Full original content (not humanized)
├── entries/         ←  Entry notes (humanized, template-aware)
├── concepts/        ←  Shared vocabulary across sources
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

## Scripts

| Script | Purpose |
|---|---|
| `process-inbox.sh` | Ingest: Source → Entry → Concepts → MoCs. Supports `--interactive` flag |
| `review-pass.sh` | Review processed entries: `--untouched`, `--last N`, `--topic TAG`, `--entry NAME`, `--interactive` |
| `compile-pass.sh` | Cross-link, concept convergence, MoC rebuild, index rebuild, typed edges, schema review |
| `query-vault.sh` | Q&A with compound-back: answers expand wiki + update existing pages |
| `lint-vault.sh` | 9 health checks: orphans, unreviewed, stale, broken links, empty, drift, edges |
| `vault-stats.sh` | Dashboard: vault size, growth, review status, health indicators |
| `reindex.sh` | Full rebuild of wiki-index.md from scratch |
| `setup-git-hooks.sh` | Install git hooks for auto-commit and WIP protection |

## Entry Note Templates

Use the `template:` frontmatter field to select:

| Template | Sections | Use for |
|---|---|---|
| `standard` (default) | Summary, ELI5 insights, Diagrams, Open questions, Linked concepts | General articles |
| `technical` | Summary, Key Findings, Data/Evidence, Methodology, Limitations, Linked concepts | Research papers, data-heavy |
| `comparison` | Summary, Side-by-Side, Pros/Cons, Verdict, Linked concepts | Product comparisons |
| `procedural` | Summary, Prerequisites, Steps, Gotchas, Linked concepts | Tutorials, how-tos |

## Typed Edges (`edges.tsv`)

Tab-separated relationships between notes:

```
source	target	type	description
L2 Sequencing	Based Rollups	extends	Based rollups solve sequencer centralization
Entry A	Entry B	contradicts	Disagree on fee market design
Concept X	Entry Y	tested_by	Entry Y provides empirical evidence
```

Types: `extends`, `contradicts`, `supports`, `supersedes`, `tested_by`, `depends_on`, `inspired_by`

Built automatically during compile-pass. Also added during queries and reviews.

## Quick Start

```bash
# 1. Set up vault
mkdir -p ~/MyVault/{01-Raw,02-Clippings,03-Queries,04-Wiki/{sources,entries,concepts,mocs},05-Outputs/{answers,visualizations},06-Config,07-WIP,08-Archive-Raw,09-Archive-Queries,Meta/Scripts,Meta/Templates}

# 2. Copy scripts, lib, prompts, and templates
chmod +x v2/scripts/*.sh
cp v2/scripts/*.sh ~/MyVault/Meta/Scripts/
cp v2/lib/common.sh ~/MyVault/Meta/Scripts/../lib/
cp -r v2/prompts ~/MyVault/Meta/Scripts/../
cp v2/templates/*.md ~/MyVault/Meta/Templates/

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
          Drop questions in 03-Queries/, run query-vault.sh

Weekly:   Run compile-pass.sh (cross-links, concept merge, edges, schema review)
          Run review-pass.sh --untouched (review key entries)
          Run lint-vault.sh (check health)
          Run vault-stats.sh (check dashboard)

Monthly:  Run reindex.sh (if lint flags drift)
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

## Humanizer Skill Usage

| Process | What gets humanized | Where |
|---|---|---|
| `process-inbox.sh` | Entry, Concept, MoC notes | Steps 3-5 of each processor |
| `review-pass.sh` | Enriched/updated entries | During enrich/update |
| `compile-pass.sh` | MoC notes (rebuild), schema review | Operations 3, 9 |
| `query-vault.sh` | Entry answers + new Concepts + compound-back updates | Steps 5-9 |
| `lint-vault.sh` | None (read-only) | — |

## Notes

- Scripts use `set -uo pipefail` (not `set -e`). Errors are handled explicitly via `|| result=$?` pattern. This is intentional — transient failures (API rate limits, file races) should retry, not abort.
- `setup-git-hooks.sh` intentionally does not source `lib/common.sh` — it runs during initial setup before the library exists.
- Lock files use `mkdir` (atomic on POSIX) instead of `touch` (TOCTOU race).
- `md5sum` has portable fallbacks: `md5 -q` (macOS) → `cksum` (any system).
- Tested with bash 4.4+. Run `shellcheck v2/scripts/*.sh` for static analysis.
