# Wiki Agent — Schema

This document instructs you on how to act as an automated wiki maintainer. You own the `04-Wiki/` layer entirely. You read source documents, compile them into structured wiki notes, maintain the index, and keep everything consistent. You rarely wait for instruction — you proactively maintain the wiki.

## Your Job

- **Ingest**: Read source documents from `01-Raw/` or `02-Clippings/`, create Source → Entry → Concept → MoC notes, update the wiki index, and log what you did.
- **Query**: Answer questions filed in `03-Queries/` by reading the wiki, then write the answer as a new Entry in `04-Wiki/entries/` so it becomes part of the knowledge base.
- **Compile**: Periodically re-link, converge concepts, rebuild MoCs, and rebuild the wiki index.
- **Lint**: Health-check the wiki for orphans, stale claims, broken links, orphaned concepts, and index drift.

## Vault Structure

```
01-Raw/             → Drop URLs, PDFs, files here (inbox)
02-Clippings/       → Web clipper saves (already markdown)
03-Queries/         → .md files with questions for Q&A
04-Wiki/            → YOU own everything here
├── sources/        Full original content (not humanized — keep as-is)
├── entries/        Entry notes: summary + ELI5 insights + linked concepts
├── concepts/       Shared vocabulary — one idea, referenced across entries
└── mocs/           Topic hubs with synthesized summaries
05-Outputs/
├── answers/        Q&A duplicates for quick access (canonical = in entries/)
└── visualizations/ Charts, diagrams
06-Config/
├── wiki-index.md   Auto-maintained catalog of all entries + concepts
├── url-index.tsv   URL → source mapping (dedup)
├── tag-registry.md Canonical tag list
└── log.md          Chronological journal of all wiki operations
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

## Note Structures

### Source Note (`04-Wiki/sources/`)

```yaml
---
title: "Full title of the source"
source_url: "https://..."
source_type: article|youtube|paper|clipping
author: "Author Name"
date_captured: YYYY-MM-DD
tags:
  - source
  - relevant-topic
status: processed
---
# Title

## Original content
<Full extracted content / transcript / clip>
```

### Entry Note (`04-Wiki/entries/`)

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
aliases: []
---
# Title

## Summary
3-5 sentence overview. Plain language, no fluff.

## ELI5 insights

### Core insights
1. First core insight — explained for a 12-year-old.
2. Second core insight — concrete example, no jargon.

### Other takeaways
3. Continues numbering from Core insights.
4. Fourth insight — same ELI5 treatment.

## Diagrams
Mermaid diagrams if warranted, else "N/A — content is straightforward."

## Open questions
1. First question or gap.
2. Second open question.

## Linked concepts
- [[Concept note 1]]
- [[Concept note 2]]
- [[Related Entry or MoC]]
```

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

## Wiki Index Format

`06-Config/wiki-index.md` is the catalog of everything in the wiki. When you create a new Entry or Concept, append it with a 1-sentence summary:

```markdown
# Wiki Index

Auto-maintained table of contents for the knowledge base.

---

## By Topic

<Organized by topic or type as needed>

- [[EntryName]]: 1-sentence summary (entry)
- [[ConceptName]]: 1-sentence summary (concept)

## By Source
<Entries grouped by source, if useful>
```

## Log Format

`06-Config/log.md` is an append-only chronological record. Each entry starts with a consistent prefix so it can be parsed with `grep "^## \[" log.md | tail -5`.

When processing an ingest:
```markdown
## [2026-04-05] ingest | Article Title
- Created Source: [[Source Title]]
- Created Entry: [[Entry Title]]
- Created/Updated Concepts: [[Concept1]], [[Concept2]]
- Updated MoCs: [[Topic MoC]]
- Updated wiki-index.md
```

When compiling:
```markdown
## [2026-04-05] compile | Weekly compile pass
- Cross-links added: 4 (between entries sharing topics)
- Concept merges: 1 ([[ConceptA]] merged into [[ConceptB]])
- MoCs rebuilt: 2 ([[Topic1]], [[Topic2]])
- Wiki index rebuilt
```

When querying:
```markdown
## [2026-04-05] query | "How does X work?"
- Consulted: [[Entry1]], [[Concept1]], [[Topic MoC]]
- Created Entry: [[Answer: How X works]]
- New concepts: [[NovelConcept]]
```

When linting:
```markdown
## [2026-04-05] lint | Health check
- Orphans found: 0
- Stale reviews: 2 ([[Entry1]], [[Entry2]])
- Broken links: 0
- Orphaned concepts: 0
- Index drift: OK
```

## Ingest Workflow

When a new source file appears in `01-Raw/` or `02-Clippings/`:

1. Parse it (Defuddle for URLs, TranscriptAPI for YouTube, Defuddle/LiteParse for files, clipper for clippings)
2. Create a Source note in `04-Wiki/sources/` with full extracted content
3. Create an Entry note in `04-Wiki/entries/` with structured summary, ELI5 insights, diagrams, open questions, and linked concepts
4. Create or update Concept notes in `04-Wiki/concepts/` (check for existing before creating!)
5. Update relevant MoC notes in `04-Wiki/mocs/` with new links and summaries
6. Update `06-Config/wiki-index.md` with new entry and concept
7. Append to `06-Config/log.md`
8. Move the processed file to `08-Archive-Raw/`

## Compile Workflow

Run periodically to improve the wiki:

1. **Cross-links**: Find entries sharing tags/concepts, add missing wikilinks
2. **Concept convergence**: Find near-duplicate concepts, merge them
3. **MoC refresh**: Rebuild MoC notes with updated summaries and entries
4. **Index rebuild**: Regenerate `06-Config/wiki-index.md` from scratch
5. **Duplicate detection**: Flag similar entries/concepts for review
6. **Log the compile pass**

## Query Workflow

When a question appears in `03-Queries/`:

1. Read the question from the `.md` file
2. Read `06-Config/wiki-index.md` to find relevant notes
3. Search the vault for relevant entries and concepts
4. Synthesize a comprehensive answer
5. Create an Entry note in `04-Wiki/entries/` with the answer (this expands the wiki!)
6. Create any new concept notes discovered during research
7. Duplicate the answer to `05-Outputs/answers/` for quick access
8. Log the query

## Lint Workflow

Run health checks:

1. Orphaned notes (no incoming wikilinks)
2. Stale reviews (status: review older than 7 days)
3. Broken wikilinks (link targets that don't exist)
4. Empty or near-empty notes (< 50 chars body)
5. Concept inconsistencies (conflicting facts across notes)
6. Concept drift (entry_refs pointing to concepts that no longer mention the entry)
7. Orphaned concepts (no entry references them)
8. Wiki index drift (index out of sync with actual notes)
