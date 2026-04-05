# Obsidian AI-Automated PKM Vault

Automated knowledge management system that turns raw web content, PDFs, and YouTube videos into a self-compiling wiki — all humanized to sound natural.

**v2.1 (Karpathy-style)** — A self-compiling wiki with visual numbering (01-09). Separate workflow folders for Raw, Clippings, Queries, and Archives. Entries use numbered list items inside standard markdown headings. Concepts are shared across sources. The wiki index replaces RAG as the retrieval layer. Located in `v2/`.

**v1 (linear pipeline)** — The original one-shot inbox processor. Located at the repo root (`scripts/`, `docs/`, `templates/`).

## Quick Decision Guide

| | v1 (current root) | v2.1 (new) |
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

## v2.1: Karpathy-Style Wiki (Recommended)

### Vault Structure

```
01-Raw/              →  Drop URLs, PDFs, files here
02-Clippings/        →  Web clipper saves (already markdown)
03-Queries/          →  Drop .md files with questions for Q&A
04-Wiki/
├── sources/         ←  Full original content (not humanized)
├── entries/         ←  Entry notes (numbered list items inside sections)
├── concepts/        ←  Shared ideas across sources (cross-source vocabulary)
└── mocs/            ←  Topic hubs with synthesized summaries
05-Outputs/
├── answers/         ←  Q&A responses (duplicate for quick access)
└── visualizations/  ←  Charts, diagrams
06-Config/
├── wiki-index.md     — Auto-maintained table of contents
├── url-index.tsv     — URL → entry mapping for dedup
├── tag-registry.md   — Canonical tag list
├── log.md            — Structured activity log ([YYYY-MM-DD] format, parseable)
└── agents.md         — Schema: tells any LLM agent how to maintain the wiki
07-WIP/              ←  Your drafts (untouched by automation)
08-Archive-Raw/      ←  Processed inbox items
09-Archive-Queries/  ←  Answered queries
```

### Entry Note Structure

Every Entry in `04-Wiki/entries/` has numbered list **items inside** standard markdown headings:

```markdown
---
title: "Title"
source: "[[Source note]]"
date_entry: YYYY-MM-DD
tags:
  - entry
  - topic-tag-1
status: review
aliases: []
---

# Title

## Summary
3-5 sentence overview. Plain language, no fluff.

## ELI5 insights

### Core insights

1. First core insight — explained for a 12-year-old.
2. Second core insight — concrete example, no jargon.
3. Third core insight — as many as exist.

### Other takeaways

4. Continues numbering from Core insights.
5. Fourth insight — same ELI5 treatment.

## Diagrams
Mermaid diagrams if warranted, else "N/A — content is straightforward."

## Open questions

1. First question or gap from the source.
2. Second open question.

## Linked concepts

- [[Concept note 1]]
- [[Concept note 2]]
- [[Related Entry or MoC]]
```

### Quick Start

```bash
# 1. Clone and set up vault
git clone https://github.com/0xminion/obsidian-automation
mkdir -p ~/MyVault/{01-Raw,02-Clippings,03-Queries,04-Wiki/{sources,entries,concepts,mocs},05-Outputs/{answers,visualizations},06-Config,07-WIP,08-Archive-Raw,09-Archive-Queries,Meta/Scripts,Meta/Templates}

# 2. Copy v2.1 scripts and templates
chmod +x obsidian-automation/v2/scripts/*.sh
cp obsidian-automation/v2/scripts/*.sh ~/MyVault/Meta/Scripts/
cp obsidian-automation/v2/templates/*.md ~/MyVault/Meta/Templates/

# 3. Process inbox
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/process-inbox.sh

# 4. Recompile wiki (weekly)
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/compile-pass.sh

# 5. Query the wiki (drop .md in 03-Queries/)
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

See `v2/` for the Karpathy-aligned approach.

---

## Humanizer Skill Usage

The Humanizer skill is active in these v2.1 processes:

| Process | What gets humanized | Where |
|---|---|---|
| `process-inbox.sh` | Entry, Concept, MoC notes | Steps 3-5 of each processor |
| `compile-pass.sh` | MoC notes + Concept notes (rebuild) | Operation 2 |
| `query-vault.sh` | Entry answers + new Concepts | Step 8 |
| `lint-vault.sh` | None (read-only) | — |

The Humanizer is declared as available in `COMMON_INSTRUCTIONS` and every processing prompt explicitly instructs the agent to "humanize before writing." The agent's runtime loads the Humanizer skill and applies pattern removal before final file writes.

## Repository Structure

```
obsidian-automation/
├── README.md                        # This file
├── docs/                            # v1 guides
├── scripts/                         # v1 scripts
├── templates/                       # v1 templates
├── skills/                          # Skill references
└── v2/                              # Karpathy-style wiki (v2.1 recommended)
    ├── README.md                    # Full v2.1 guide
    ├── docs/                        # v2 setup guides (Part1, Part2)
    ├── scripts/                     # v2.1 scripts (numbered 01-09 structure)
    └── templates/                   # Entry, Concept, MoC, Source...
```
