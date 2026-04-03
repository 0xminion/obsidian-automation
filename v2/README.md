# v2: Obsidian AI-Automated PKM Vault — Karpathy-Style Wiki

Automated knowledge management system that turns raw web content, PDFs, and YouTube videos into a self-compiling wiki. Inspired by Andrej Karpathy's "LLM Knowledge Bases" approach: raw data is collected, compiled by an LLM into a .md wiki, operated on for Q&A, and incrementally enhanced. You rarely ever write the wiki manually.

## Vault Structure

```
01-Raw/             →  Drop URLs, PDFs, files here
02-Clippings/        →  Web clipper saves (already markdown)
03-Queries/          →  Drop .md files with questions for Q&A
04-Wiki/
├── sources/         ←  Full original content (not humanized)
├── entries/         ←  Entry notes (humanized, numbered list items)
├── concepts/        ←  Shared vocabulary across sources (humanized)
└── mocs/            ←  Topic hubs with synthesized summaries (humanized)
05-Outputs/
├── answers/         ←  Q&A responses (duplicate for quick access)
└── visualizations/  ←  Charts, diagrams, exports
06-Config/
├── wiki-index.md    ←  Auto-maintained TOC (retrieval layer — no RAG)
├── url-index.tsv    ←  URL → entry mapping (dedup)
└── tag-registry.md  ←  Canonical tag list
07-WIP/              ←  Your drafts (untouched by automation)
08-Archive-Raw/      ←  Processed inbox items
09-Archive-Queries/  ←  Answered queries
```

Numbering gives visual ordering in Obsidian's file tree while keeping different workflow types separate (Raw vs Clippings vs Queries, Archive-Raw vs Archive-Queries).

## Entry Note Structure

Every Entry in `04-Wiki/entries/` has numbered list items **inside** standard markdown headings:

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

## Scripts

| Script | Purpose |
|---|---|
| `process-inbox.sh` | Ingest: Source → Entry → Concepts → MoCs + wiki index |
| `compile-pass.sh` | Cross-link, concept convergence, MoC rebuild, index rebuild |
| `query-vault.sh` | Q&A: drop question in 03-Queries/ → answer as Entry back into wiki |
| `lint-vault.sh` | 8 health checks: orphans, stale, broken links, empty, drift, etc. |

## Key Features

- **Visual ordering**: 01 through 09 gives clear workflow progression in file tree
- **Separate workflows**: Raw vs Clippings vs Queries have distinct folders
- **Numbered list content**: ELI5 insights and Open questions use ordered lists (1. 2. 3.)
- **Concept convergence**: Searches existing concepts before creating, merges near-duplicates
- **Wiki index**: Auto-maintained TOC as retrieval layer — no RAG needed
- **Query expansion**: Answers written as Entries back into wiki, expanding the knowledge base
- **Humanizer**: All Entry, Concept, and MoC prose passes through the Humanizer skill before writing

## Quick Start

```bash
# 1. Set up vault
mkdir -p ~/MyVault/{01-Raw,02-Clippings,03-Queries,04-Wiki/{sources,entries,concepts,mocs},05-Outputs/{answers,visualizations},06-Config,07-WIP,08-Archive-Raw,09-Archive-Queries,Meta/Scripts,Meta/Templates}

# 2. Copy scripts and templates
chmod +x v2/scripts/*.sh
cp v2/scripts/*.sh ~/MyVault/Meta/Scripts/
cp v2/templates/*.md ~/MyVault/Meta/Templates/

# 3. Process
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/process-inbox.sh   # Ingest
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/compile-pass.sh    # Recompile
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/query-vault.sh     # Query
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/lint-vault.sh      # Lint
```

## Humanizer Skill Usage

| Process | What gets humanized | Where |
|---|---|---|
| `process-inbox.sh` | Entry, Concept, MoC notes | Steps 3-5 of each processor |
| `compile-pass.sh` | MoC notes (rebuild) | Operation 2 |
| `query-vault.sh` | Entry answers + new Concepts | Step 8 |
| `lint-vault.sh` | None (read-only) | — |

<!--
  Note: Humanizer MUST be run before any content goes into:
  - 04-Wiki/entries/
  - 04-Wiki/concepts/
  - 04-Wiki/mocs/
  - 05-Outputs/answers/
-->
