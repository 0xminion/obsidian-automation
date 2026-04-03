# Obsidian AI-Automated PKM Vault

Automated knowledge management system that turns raw web content, PDFs, and YouTube videos into a self-compiling wiki — all humanized to sound natural.

**v2 (Karpathy-style)** — A self-compiling wiki with numbered folder structure. Entries use numbered sections. Concepts are shared across sources. The wiki index replaces RAG. Located in `v2/`.

**v1 (linear pipeline)** — The original one-shot inbox processor. Located at the repo root (`scripts/`, `docs/`, `templates/`).

## Quick Decision Guide

| | v1 (current root) | v2 (new) |
|---|---|---|
| **Philosophy** | Pipeline: inbox → notes → archive | Wiki: inbox → self-compiling knowledge base |
| **Note structure** | Source → Distilled → Atomic → MoC | Source → Entry → Concept → MoC |
| **Concepts** | Per-source (one Atomic per idea) | Shared vocabulary across all sources |
| **Retrieval** | Manual search | wiki-index.md (auto-maintained TOC with summaries) |
| **Self-improves** | No — one-shot processing | Yes — compile pass cross-links, merges, rebuilds |
| **Q&A** | Answers → WIP (dead-ended) | Answers → Entries back into wiki (expands knowledge) |
| **Linting** | Basic (orphans, broken links) | 8 checks including concept consistency + drift |
| **Who** | Start here, it works | Want Karpathy's "living wiki" vision |

---

## v2: Karpathy-Style Wiki (Recommended)

### Vault Structure

```
00-WIP/              ←  Your drafts (untouched by automation)
01-Raw/              →  Drop URLs, PDFs, files, queries here
02-Wiki/
├── sources/         ←  Full original content (not humanized)
├── entries/         ←  Entry notes (numbered sections, humanized)
├── concepts/        ←  Shared vocabulary across sources (humanized)
└── mocs/            ←  Topic hubs with synthesized summaries (humanized)
03-Outputs/
├── answers/         ←  Q&A responses (duplicates for quick access)
└── visualizations/  ←  Charts, diagrams, exports
04-Config/
├── wiki-index.md    ←  Auto-maintained TOC (retrieval layer — no RAG)
├── url-index.tsv    ←  URL → entry mapping (dedup)
└── tag-registry.md  ←  Canonical tag list
05-Archive/          ←  Processed inbox items and queries
```

### Entry Note Structure (Numbered Sections)

Every Entry in `02-Wiki/entries/` follows this exact numbered structure:

```markdown
---
title: "Title"
source: "[[Source note]]"
date_entry: YYYY-MM-DD
tags:
  - entry
  - topic-tag-1
  - ... (5-10 topic tags)
status: review
aliases: []
---

# Title

1. Summary
3-5 sentence overview. Plain language, no fluff.

2. ELI5 insights

   2a. Core insights
   Main findings explained for a smart 12-year-old. As many as exist.

   2b. Other takeaways
   Other important findings. Same ELI5 treatment.

3. Diagrams
Mermaid diagrams if warranted, else "N/A — content is straightforward."

4. Open questions
Gaps, assumptions, what the source doesn't answer.

5. Linked concepts
Wikilinks to Concept notes, other Entries, MoCs.
```

### Quick Start

```bash
# 1. Clone and set up vault
git clone https://github.com/0xminion/obsidian-automation
mkdir -p ~/MyVault/{00-WIP,01-Raw,02-Wiki/{sources,entries,concepts,mocs},03-Outputs/{answers,visualizations},04-Config,05-Archive,Meta/Scripts,Meta/Templates}

# 2. Copy v2 scripts and templates
chmod +x obsidian-automation/v2/scripts/*.sh
cp obsidian-automation/v2/scripts/*.sh ~/MyVault/Meta/Scripts/
cp obsidian-automation/v2/templates/*.md ~/MyVault/Meta/Templates/

# 3. Process inbox
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/process-inbox.sh

# 4. Recompile wiki (weekly)
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/compile-pass.sh

# 5. Query the wiki
# Drop a .md in 01-Raw/, then:
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/query-vault.sh

# 6. Health check
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/lint-vault.sh
```

---

## v1: Linear Pipeline

The original implementation. Still functional but doesn't self-improve.

### Vault Structure

```
00-Inbox/
├── raw/            →  Drop URLs, PDFs, files
├── clippings/      →  Web clipper saves
├── quick notes/    →  Manual notes (untouched)
├── queries/        →  Q&A questions
└── failed/         →  Processing failures
01-Sources/         ←  Full original content
02-Distilled/       ←  AI summaries (## Summary → ELI5 → Diagrams)
03-Atomic/          ←  One idea per note
04-MoCs/            ←  Topic hubs
05-WIP/             ←  User drafts
06-Archive/         ←  Processed items
```

See `v2/` for the Karpathy-aligned approach. See `docs/` and `scripts/` for v1 full setup.

---

## Humanizer Skill Usage

The Humanizer skill is active in these v2 processes:

| Process | What gets humanized | Where |
|---|---|---|
| `process-inbox.sh` | Entry, Concept, MoC notes | Steps 3-5 of each processor |
| `compile-pass.sh` | MoC notes (rebuild) | Operation 2 |
| `query-vault.sh` | Entry answers + Concepts | Step 8 |
| `lint-vault.sh` | None (read-only) | — |

## Repository Structure

```
obsidian-automation/
├── README.md                        # This file
├── docs/                            # v1 guides
├── scripts/                         # v1 scripts
├── templates/                       # v1 templates
├── skills/                          # Skill references
└── v2/                              # Karpathy-style wiki (recommended)
    ├── README.md                    # Full v2 guide
    ├── docs/                        # v2 setup guides
    ├── scripts/                     # v2 scripts (numbered structure)
    └── templates/                   # v2 templates (Entry, Concept, MoC...)
```
