# v2: Vault Structure Setup

## Numbered Folder Structure (v2)

```
01-Raw/              →  Drop URLs, PDFs, files here
02-Clippings/        →  Web clipper saves (already markdown)
03-Queries/          →  Drop .md files with questions for Q&A
04-Wiki/
├── sources/         ←  Full original content (not humanized)
├── entries/         ←  Entry notes (humanized, numbered list items inside sections)
├── concepts/        ←  Shared vocabulary across sources (humanized)
└── mocs/            ←  Topic hubs with synthesized summaries (humanized)
05-Outputs/
├── answers/         ←  Q&A responses (duplicates for quick access)
└── visualizations/  ←  Charts, diagrams, exports
06-Config/
├── wiki-index.md    ←  Auto-maintained TOC (retrieval layer — no RAG)
├── url-index.tsv    ←  URL → entry mapping (dedup)
└── tag-registry.md  ←  Canonical tag list
07-WIP/              ←  Your drafts (untouched by automation)
08-Archive-Raw/      ←  Processed inbox items
09-Archive-Queries/  ←  Answered queries
```

Numbering gives visual ordering in Obsidian's file tree while keeping different workflow types separate.

## Quick Setup

```bash
# 1. Create vault structure
mkdir -p ~/MyVault/{01-Raw,02-Clippings,03-Queries,04-Wiki/{sources,entries,concepts,mocs},05-Outputs/{answers,visualizations},06-Config,07-WIP,08-Archive-Raw,09-Archive-Queries,Meta/Scripts,Meta/Templates}

# 2. Install tools
npm install -g defuddle @llamaindex/liteparse

# 3. Copy scripts and templates
chmod +x v2/scripts/*.sh
cp v2/scripts/*.sh ~/MyVault/Meta/Scripts/
cp v2/templates/*.md ~/MyVault/Meta/Templates/
```
