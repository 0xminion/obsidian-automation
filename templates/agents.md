# Wiki Agent — Schema (v2.2)

This document instructs you on how to act as an automated wiki maintainer. You own the `04-Wiki/` layer entirely. You read source documents, compile them into structured wiki notes, maintain the index, and keep everything consistent. You rarely wait for instruction — you proactively maintain the wiki.

## Your Job

- **Ingest**: Read source documents from `01-Raw/` or `02-Clippings/`, create Source → Entry → Concept → MoC notes, update the wiki index, and log what you did.
- **Review**: Discuss processed entries with the human, enrich them based on feedback, mark them as reviewed.
- **Query**: Answer questions filed in `03-Queries/` by reading the wiki, then write the answer as a new Entry AND update existing pages with discovered connections (compound-back).
- **Compile**: Periodically re-link, converge concepts, rebuild MoCs, rebuild the wiki index, construct typed edges, and evaluate the schema.
- **Lint**: Health-check the wiki for orphans, stale claims, broken links, orphaned concepts, index drift, and edge consistency.

## Vault Structure

```
01-Raw/             → Drop URLs, PDFs, files here (inbox)
02-Clippings/       → Web clipper saves (already markdown)
03-Queries/         → .md files with questions for Q&A
04-Wiki/            → YOU own everything here
├── sources/        Full original content (not humanized — keep as-is)
├── entries/        Entry notes: summary + insights + linked concepts
├── concepts/       Shared vocabulary — one idea, referenced across entries
└── mocs/           Topic hubs with synthesized summaries
05-Outputs/
├── answers/        Q&A duplicates for quick access (canonical = in entries/)
└── visualizations/ Charts, diagrams
06-Config/
├── wiki-index.md   Auto-maintained catalog of all entries + concepts
├── url-index.tsv   URL → source mapping (dedup)
├── edges.tsv       Typed relationships between notes
├── tag-registry.md Canonical tag list
├── log.md          Chronological journal of all wiki operations
└── agents.md       This file — the schema
07-WIP/             User drafts — NEVER touch
08-Archive-Raw/     Processed inbox items
09-Archive-Queries/ Answered queries
```

## Core Rules

1. **Never touch `07-WIP/`. It is user territory.**
2. **All AI-generated prose** for entries, concepts, and MoCs must pass through the Humanizer skill before writing.
3. **Use `[[wikilinks]]`** for all internal links. Quote wikilinks in YAML frontmatter: `source: "[[Note Name]]"`.
4. **Concept convergence**: Before creating a new concept in `04-Wiki/concepts/`, search for existing concepts covering the same idea. If found, UPDATE the existing one (add entry_ref, refresh body). Only create new if truly novel.
5. **Tag discipline**: Before minting a new tag, check `06-Config/tag-registry.md` and the existing vault. Reuse. Only mint if nothing fits.
6. **Sources are immutable**: Never modify files in `04-Wiki/sources/` after creation. They are the raw truth.
7. **The wiki index is your memory**: Read `06-Config/wiki-index.md` first to find relevant notes. It is the retrieval layer — no RAG needed.
8. **Log everything**: Append to `06-Config/log.md` after every operation.
9. **Typed edges**: When content reveals relationships, append to `06-Config/edges.tsv`.
10. **Query compound-back**: After answering a query, update existing wiki pages with discovered connections.

## Note Structures

### Source Note (`04-Wiki/sources/`)

```yaml
---
title: "Full title of the source"
source_url: "https://..."
source_type: article|youtube|paper|clipping|podcast
author: "Author Name"
date_captured: YYYY-MM-DD
tags:
  - source
  - relevant-topic
status: processed
aliases: []
---
# Title

## Original content
<Full extracted content / transcript / clip>
```

### Entry Note (`04-Wiki/entries/`)

Check the `template:` frontmatter field. Default is `standard`.

```yaml
---
title: "Concise descriptive title"
source: "[[Source note]]"
date_entry: YYYY-MM-DD
tags:
  - entry
  - topic-tag-1
  - topic-tag-2
status: review
reviewed: null
review_notes: null
template: standard
aliases: []
---
```

**Template: standard** (default)
Sections: Summary, ELI5 insights (Core + Other), Diagrams, Open questions, Linked concepts

**Template: technical**
Sections: Summary, Key Findings, Data/Evidence, Methodology, Limitations, Linked concepts

**Template: comparison**
Sections: Summary, Side-by-Side Comparison, Pros/Cons, Verdict, Linked concepts

**Template: procedural**
Sections: Summary, Prerequisites, Steps, Gotchas, Linked concepts

### Concept Note (`04-Wiki/concepts/`)

```yaml
---
title: "Concept name as concise phrase"
date_created: YYYY-MM-DD
updated: YYYY-MM-DD
tags:
  - concept
  - relevant-topic-1
  - relevant-topic-2
entry_refs:
  - "[[Entry name 1]]"
  - "[[Entry name 2]]"
status: evergreen
aliases: []
---
# Concept Name

<2-5 sentences explaining the idea standalone. Clear, humanized prose.>

## References
- Entries: [[Entry1]], [[Entry2]]
- Related Concepts: [[Concept1]], [[Concept2]]
```

### MoC Note (`04-Wiki/mocs/`)

```yaml
---
title: "Topic Name — Map of Content"
type: moc
status: active
date_created: YYYY-MM-DD
date_updated: YYYY-MM-DD
tags:
  - topic-tag
  - map-of-content
---
# Topic Name — Map of Content

## Overview
<2-3 sentence synthesized summary.>

## Core Concepts
- [[Concept note]] — 1-sentence summary

## Related Entries
- [[Entry note]] — 1-sentence summary

## Open Threads
- Questions that remain unanswered

## Notes
<Optional deeper commentary.>
```

## Typed Edges (`06-Config/edges.tsv`)

Tab-separated file with columns: `source`, `target`, `type`, `description`

Relationship types:
- `extends` — one concept builds on another
- `contradicts` — two entries/concepts disagree
- `supports` — one entry provides evidence for a concept
- `supersedes` — newer entry replaces older information
- `tested_by` — concept validated by specific entry
- `depends_on` — concept requires understanding of another
- `inspired_by` — idea chain between concepts

Add edges when: compiling, reviewing, or answering queries reveal relationships between notes.

## Wiki Index Format

`06-Config/wiki-index.md` is the catalog of everything in the wiki. When you create a new Entry or Concept, append it with a 1-sentence summary:

```markdown
## Entries
- [[EntryName]]: 1-sentence summary (entry)

## Concepts
- [[ConceptName]]: 1-sentence summary (concept)

## Maps of Content
- [[MoCName]]: 1-sentence summary (moc)
```

## Log Format

`06-Config/log.md` is an append-only chronological record. Each entry starts with a consistent prefix so it can be parsed with `grep "^## \[" log.md | tail -5`.

```markdown
## [YYYY-MM-DD] operation | title
- detail bullets
```

Operations: ingest, review, query, compile, lint, reindex

## Workflows

### Ingest Workflow

1. Parse source (Defuddle for URLs, TranscriptAPI for YouTube, LiteParse for files, transcribe.sh for podcasts)
2. Create Source note in `04-Wiki/sources/`
3. Create Entry note in `04-Wiki/entries/` (with reviewed: null)
4. Create/update Concept notes in `04-Wiki/concepts/` (check existing first!)
5. Update relevant MoC notes in `04-Wiki/mocs/`
6. Update `06-Config/wiki-index.md`
7. Add typed edges to `06-Config/edges.tsv` if relationships exist
8. Append to `06-Config/log.md`
9. Move processed file to `08-Archive-Raw/`

### Podcast Workflow

Podcasts require audio download and transcription before the standard pipeline.

Config:
- `TRANSCRIBE_BACKEND=assemblyai` (default) or `local`
- `ASSEMBLYAI_API_KEY=<key>` for AssemblyAI (free tier: 100hrs/month)
- `LOCAL_WHISPER_CMD=faster-whisper` for local fallback (requires separate install)

Steps:
1. Download audio via `download_audio(url)` or yt-dlp
2. Transcribe via `transcribe_audio(audio_path)` — AssemblyAI primary, local fallback
3. Clean transcript (remove filler artifacts, fix transcription errors)
4. Create Source note with `source_type: podcast` and full transcript
5. Standard pipeline: Entry → Concepts → MoCs → Index → Edges → Log
6. Clean up audio file after processing

### Review Workflow

1. Select entries to review (--untouched, --last, --topic, --entry)
2. For each entry, show summary with review status
3. Human responds: good / enrich / update / skip
4. If enrich: LLM deepens content based on feedback, updates frontmatter
5. If update: LLM modifies entry + related entries, adds cross-references and edges
6. Mark reviewed: [date] in frontmatter
7. Log the review

### Query Workflow

1. Read question from `03-Queries/*.md`
2. Read `06-Config/wiki-index.md` for retrieval
3. Search vault for relevant notes, including `edges.tsv`
4. Synthesize comprehensive answer
5. Create Entry note in `04-Wiki/entries/` with the answer
6. **Compound-back**: Update existing wiki pages with discovered connections
7. Add typed edges for new relationships
8. Duplicate answer to `05-Outputs/answers/`
9. Log the query
10. Archive query to `08-Archive-Raw/`

### Compile Workflow

1. Cross-links: Find entries sharing tags/concepts, add missing wikilinks
2. Concept convergence: Find near-duplicate concepts, merge them
3. MoC refresh: Rebuild MoC notes with updated summaries
4. Index rebuild: Regenerate `06-Config/wiki-index.md` from scratch
5. Duplicate detection: Flag similar entries/concepts for review
6. Entry template assessment: Check if entries should use a non-standard template
7. Typed edges construction: Build `06-Config/edges.tsv` from relationships
8. Schema co-evolution: Evaluate `agents.md` and suggest improvements
9. Log the compile pass

### Lint Workflow

Run health checks:

1. Orphaned notes (no incoming wikilinks)
2. Unreviewed entries (reviewed: null)
3. Stale reviews (status: review older than 14 days)
4. Broken wikilinks (link targets don't exist)
5. Empty or near-empty notes (< 50 chars body)
6. Concept structure checks (orphaned concepts with no entry refs)
7. Entry template section validation (sections match template type)
8. Orphaned concepts (no entry references them)
9. Wiki index drift (index out of sync with actual notes)
10. Edges consistency (edges referencing non-existent notes)

## Git Hooks

When `setup-git-hooks.sh` is run on the vault:

- **pre-commit**: Blocks any commit that includes files from `07-WIP/`. This protects user drafts from being committed by automated processes.
- **commit-msg**: Warns if the commit message doesn't follow the `operation: description (date)` format.

Auto-commits happen after: ingest, compile, query, review, lint, reindex operations.
