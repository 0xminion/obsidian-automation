# Obsidian AI-Automated PKM Vault

Automated knowledge management system that turns raw web content, PDFs, and YouTube videos into a structured wiki — all humanized to sound natural. Supports incremental compilation, Q&A, and linting for wiki health.

**v2 (Karpathy-style)** — A self-compiling wiki that grows and improves itself over time. Entries preserve the Distilled structure you know. Concepts are shared across sources. The wiki index replaces RAG as the retrieval layer. Located in `v2/`.

**v1 (linear pipeline)** — The original one-shot inbox processor. Mature, well-tested. Located at the repo root (`scripts/`, `docs/`, `templates/`).

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

Based on Andrej Karpathy's "LLM Knowledge Bases" approach: raw data is collected, compiled by an LLM into a .md wiki, operated on for Q&A, and incrementally enhanced. You rarely ever write the wiki manually.

```
vault/
├── raw/                 →  Drop URLs, PDFs, files here
├── clippings/           →  Web clipper saves
├── wiki/
│   ├── entries/         ←  Entry notes (Summary + ELI5 + Diagrams + Links)
│   ├── concepts/        ←  Shared ideas across sources (cross-source vocabulary)
│   └── mocs/            ←  Topic hubs with synthesized summaries
├── outputs/
│   ├── answers/         ←  Q&A responses (duplicate for quick access)
│   └── visualizations/  ←  Charts, diagrams
├── queries/             →  Drop .md files with questions
├── config/
│   ├── wiki-index.md    ←  Auto-maintained TOC (retrieval layer — no RAG)
│   ├── url-index.tsv    ←  URL → entry mapping (dedup)
│   └── tag-registry.md  ←  Canonical tag list
├── 05-WIP/              ←  Your drafts (untouched by automation)
├── raw-archive/         ←  Processed inbox items
└── query-archive/       ←  Answered queries
```

### Entry Note Structure (preserves your Distilled format)

Every Entry in `wiki/entries/` follows this exact structure:

```markdown
---
title: "Title"
source: "[[Source note]]"
date_entry: 2026-04-03
tags:
  - entry
  - topic-tag-1
  - topic-tag-2
status: review
aliases: []
---

# Title

## Summary
3-5 sentence overview. Plain language, no fluff.

## ELI5 insights

### Core insights
Main findings explained for a smart 12-year-old. As many as exist.

### Other takeaways
Other important findings. Same ELI5 treatment.

## Diagrams
Mermaid diagrams if warranted, else "N/A — content is straightforward."

## Open questions
Gaps, assumptions, what the source doesn't answer.

## Linked concepts
Wikilinks to Concept notes, other Entries, MoCs.
```

### Quick Start

```bash
# 1. Clone and set up vault
cd obsidian-automation
mkdir -p ~/MyVault
cd ~/MyVault
mkdir -p raw clippings wiki/entries wiki/concepts wiki/mocs
mkdir -p outputs/answers outputs/visualizations
mkdir -p queries config 05-WIP raw-archive query-archive

# 2. Copy v2 scripts and templates
chmod +x /path/to/obsidian-automation/v2/scripts/*.sh
cp /path/to/obsidian-automation/v2/scripts/*.sh ~/MyVault/Meta/Scripts/
cp /path/to/obsidian-automation/v2/templates/*.md ~/MyVault/Meta/Templates/

# 3. Install tools
npm install -g defuddle @llamaindex/liteparse

# 4. Set API keys
export TRANSCRIPT_API_KEY="***"
export SUPADATA_API_KEY="***"
export ANTHROPIC_API_KEY="***"

# 5. Process inbox
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/process-inbox.sh

# 6. Recompile wiki (weekly)
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/compile-pass.sh

# 7. Query the wiki
# Drop a .md in queries/, then:
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/query-vault.sh

# 8. Health check
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/lint-vault.sh
```

See `v2/README.md` for the full setup guide.

---

## v1: Linear Pipeline (Current Root)

The original implementation. Still fully functional but doesn't self-improve.

```
00-Inbox/
├── raw/                 →  Drop URLs, PDFs, files here
├── clippings/           →  Web clipper saves
├── quick notes/         →  Your manual notes (untouched by automation)
├── queries/             →  Drop .md files with questions for Q&A
└── failed/              →  Processing failures for manual review
01-Sources/              ←  Full original content (not humanized)
02-Distilled/            ←  AI summaries with ELI5 insights (humanized)
03-Atomic/               ←  One idea per note (humanized)
04-MoCs/                 ←  Topic hubs with synthesized summaries
05-WIP/                  ←  Your drafts (untouched by automation)
06-Archive/              ←  Processed items
Meta/Scripts/            ←  All scripts
Meta/Templates/          ←  Note templates
```

### Quick Start

```bash
# Create vault structure
mkdir -p ~/MyVault
cd ~/MyVault
mkdir -p "00-Inbox/raw" "00-Inbox/quick notes" "00-Inbox/clippings" "00-Inbox/queries"
mkdir -p 01-Sources 02-Distilled 03-Atomic 04-MoCs 05-WIP
mkdir -p 06-Archive/processed-inbox 06-Archive/processed-queries
mkdir -p Meta/Templates Meta/Scripts

# Copy scripts and templates
chmod +x scripts/*.sh
cp scripts/*.sh ~/MyVault/Meta/Scripts/
cp templates/*.md ~/MyVault/Meta/Templates/

# Process
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/process-inbox.sh
```

### Note Types

| Folder | Content | Humanized? |
|---|---|---|
| `01-Sources/` | Full original content | No |
| `02-Distilled/` | AI summary (Summary → ELI5 → Diagrams → Questions → Links) | Yes |
| `03-Atomic/` | One idea per note, 2-5 sentences | Yes |
| `04-MoCs/` | Topic hubs with synthesized summaries | Yes |
| `05-WIP/` | Your drafts + query answers | Never touched |

### Scripts

| Script | Purpose |
|---|---|
| `process-inbox.sh` | Main ingestion: Source → Distilled → Atomic → MoC |
| `compile-pass.sh` | Cross-link, MoC rebuild, duplicate detection |
| `query-vault.sh` | Q&A: drop question → get answer in 05-WIP/ |
| `lint-vault.sh` | Health check: orphans, stale, broken links, empty notes |

See `docs/Part1-Vault-Structure-Setup.md` and `docs/Part2-Automation-Skills-Setup.md` for full guides.

---

## Shared Dependencies

| Tool | Version | Purpose |
|---|---|---|
| Node.js | 18+ | Runtime for Defuddle, LiteParse, TranscriptAPI |
| Node.js | 22+ | Required for obsidian-headless (`ob`) |
| Obsidian CLI (`obsidian`) | 1.8+ | Note creation, search, tagging |
| Obsidian Headless (`ob`) | latest | Sync + publish without desktop app |
| Defuddle | latest | Web content extraction |
| LiteParse | latest | PDF/DOCX/PPTX parsing with OCR |
| LibreOffice | latest | Office format conversion for LiteParse |
| TranscriptAPI | — | YouTube transcript fetching (primary) |
| Supadata | — | YouTube transcript fetching (fallback) |
| Humanizer | — | AI pattern removal from generated prose |

## Repository Structure

```
obsidian-automation/
├── README.md                        # This file
├── docs/
│   ├── Part1-Vault-Structure-Setup.md    # v1 vault setup
│   └── Part2-Automation-Skills-Setup.md  # v1 full setup guide
├── scripts/
│   ├── process-inbox.sh                  # v1 inbox processor
│   ├── compile-pass.sh                   # v1 wiki recompile
│   ├── query-vault.sh                    # v1 Q&A
│   ├── lint-vault.sh                     # v1 health checks
│   ├── Dashboard.md                      # v1 Dataview dashboard
│   └── Process-Query.md                  # v1 sample query
├── templates/
│   ├── MoC.md                            # v1 Map of Content
│   └── Query.md                          # v1 Query template
├── skills/                               # Skill references
│   ├── obsidian-markdown.md
│   ├── obsidian-cli.md
│   ├── humanizer.md
│   ├── transcriptapi.md
│   └── ...
└── v2/                                   # Karpathy-style wiki
    ├── README.md                         # Full v2 guide
    ├── docs/
    │   ├── Part1-Vault-Structure-Setup.md
    │   └── Part2-Automation-Skills-Setup.md
    ├── scripts/
    │   ├── process-inbox.sh              # v2: Entry + Concept + wiki-index
    │   ├── compile-pass.sh               # v2: cross-link + concept merge
    │   ├── query-vault.sh                # v2: Q&A → Entry
    │   └── lint-vault.sh                 # v2: 8 health checks
    └── templates/
        ├── Source.md, Entry.md, Concept.md, MoC.md
        ├── Query.md, wiki-index.md, tag-registry.md
```
