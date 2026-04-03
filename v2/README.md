# v2: Obsidian AI-Automated PKM Vault — Karpathy-Style Wiki

Automated knowledge management system that turns raw web content, PDFs, and YouTube videos into a self-compiling wiki. Inspired by Andrej Karpathy's "LLM Knowledge Bases" approach: raw data is collected, compiled by an LLM into a .md wiki, operated on for Q&A, and incrementally enhanced. You rarely ever write the wiki manually.

## Vault Structure

```
00-WIP/              ←  Your drafts (untouched by automation)
01-Raw/              →  Drop URLs, PDFs, files, queries here
02-Wiki/
├── sources/         ←  Full original content (not humanized)
├── entries/         ←  Entry notes (humanized summaries)
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

## Entry Note Structure (Numbered Sections)

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

## Scripts

| Script | Purpose |
|---|---|
| `process-inbox.sh` | Ingest: Source → Entry → Concepts → MoCs + wiki index |
| `compile-pass.sh` | Cross-link, concept convergence, MoC rebuild, index rebuild |
| `query-vault.sh` | Q&A: drop question → answer as Entry back into wiki |
| `lint-vault.sh` | 8 health checks: orphans, stale, broken, empty, drift, etc. |

## Key Features

- **Numbered folder structure**: 00-WIP → 01-Raw → 02-Wiki → 03-Outputs → 04-Config → 05-Archive
- **Numbered Entry sections**: 1. Summary → 2. ELI5 (2a/2b) → 3. Diagrams → 4. Open questions → 5. Linked concepts
- **Concept convergence**: Searches existing concepts before creating new ones, merges near-duplicates
- **Wiki index**: Auto-maintained TOC as retrieval layer — no RAG needed
- **Query expansion**: Answers written as Entries back into wiki, expanding the knowledge base
- **Humanizer**: All Entry, Concept, and MoC prose passes through the Humanizer skill before writing

## Quick Start

```bash
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/process-inbox.sh   # Ingest
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/compile-pass.sh    # Recompile
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/query-vault.sh     # Query
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/lint-vault.sh      # Lint
```

See `docs/` for full setup guides.

## Humanizer Skill Usage

The Humanizer skill is active in these processes:

| Process | What gets humanized | Where it happens |
|---|---|---|
| `process-inbox.sh` | Entry notes, Concept notes, MoC notes | Steps 3-5 of each processor function |
| `compile-pass.sh` | MoC notes (during rebuild) | OPERATION 2 |
| `query-vault.sh` | Entry answers + Concept notes discovered during Q&A | Step 8 |
| `lint-vault.sh` | None (read-only) | N/A |

The Humanizer is declared as an available skill in `COMMON_INSTRUCTIONS` and every processing prompt explicitly instructs the agent to "humanize before writing." The agent's runtime loads the Humanizer skill and applies pattern removal before final file writes.
