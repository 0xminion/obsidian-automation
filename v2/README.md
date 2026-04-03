# Obsidian AI-Automated PKM Wiki — v2

A wiki-first knowledge management system that turns raw web content, PDFs, and YouTube videos into a networked wiki of Entries, Concepts, and Maps of Content — with automatic cross-linking, shared concepts, and zero RAG.

> v2 replaces the v1 pipeline model (Inbox → Distilled → Atomic → MoC) with a **wiki model** where concepts are shared across sources, not owned by one note.

## What's New in v2

| v1 | v2 |
|---|---|
| `Distilled` notes | `Entry` notes — same ELI5 structure, renamed |
| `Atomic` notes (one per source) | `Concept` notes — **shared across multiple sources** |
| `url-index.tsv` for dedup | `wiki-index.md` — auto-maintained index replaces RAG |
| No centralized tags | `tag-registry.md` — canonical tag namespace |
| Concepts pipeline-owned | Concepts are **wiki citizens** — anyone can edit, compile converges |

## Core Philosophy: Wiki, Not Pipeline

Karpathy's principle: **"Don't build a pipeline. Build a wiki."**

Your knowledge should grow organically like a wiki — notes link to each other, concepts are shared and refined over time, and the system converges rather than duplicates.

- **Entries** are your distilled summaries — one per source, same ELI5 structure you already know.
- **Concepts** are ideas shared across entries. Multiple entries can reference the same concept. The compile pass converges duplicates automatically.
- **MoCs** are topic hubs with synthesized summaries of the Concepts and Entries beneath them.
- **wiki-index.md** replaces RAG — the entire wiki structure is your retrieval index.

## Quick Start

### 1. Clone and review

```bash
cd /path/to/obsidian-automation/v2
ls templates/    # Source.md, Entry.md, Concept.md, MoC.md, Query.md, wiki-index.md, tag-registry.md
ls docs/         # Part1 + Part2 setup guides
```

### 2. Create your vault structure

```bash
cd ~/MyVault
mkdir -p wiki/{entries,concepts,mocs,sources}
mkdir -p "00-Inbox/raw" "00-Inbox/quick notes" "00-Inbox/clippings" "00-Inbox/queries"
mkdir -p 05-WIP 06-Archive/processed-inbox
mkdir -p Meta/{Templates,Scripts}
```

### 3. Copy templates

```bash
cp v2/templates/*.md ~/MyVault/Meta/Templates/
cp v2/templates/wiki-index.md ~/MyVault/
cp v2/templates/tag-registry.md ~/MyVault/Meta/
```

### 4. Follow setup guides

- [Part 1: Vault Structure Setup](docs/Part1-Vault-Structure-Setup.md)
- [Part 2: Automation & Skills Setup](docs/Part2-Automation-Skills-Setup.md)

## Templates

| Template | Purpose |
|---|---|
| Source.md | Full original content (never humanized) |
| Entry.md | Distilled entry — ELI5 summary, insights, diagrams, open questions |
| Concept.md | Shared idea across multiple sources (with `entry_refs`) |
| MoC.md | Topic hub with synthesized summaries |
| Query.md | Question template for Q&A against the wiki |
| wiki-index.md | Auto-maintained index (replaces RAG) |
| tag-registry.md | Canonical tag registry |

## Key Principle: YAML Wikilinks Must Be Quoted

YAML interprets `[[` as a nested list. Always quote wikilinks in frontmatter:

```yaml
source: "[[Source note name]]"        # Correct
entry_refs:                           # Correct
  - "[[Entry 1]]"
  - "[[Entry 2]]"
```

## Repository Structure

```
v2/
├── templates/
│   ├── Source.md          # Full original content
│   ├── Entry.md           # Distilled entry (ELI5 format)
│   ├── Concept.md         # Shared concept across sources
│   ├── MoC.md             # Topic hub / Map of Content
│   ├── Query.md           # Question template
│   ├── wiki-index.md      # Auto-maintained wiki index
│   └── tag-registry.md    # Canonical tag registry
└── docs/
    ├── Part1-Vault-Structure-Setup.md    # Vault creation guide
    └── Part2-Automation-Skills-Setup.md  # Full automation setup
```
