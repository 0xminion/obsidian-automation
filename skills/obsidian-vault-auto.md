---
name: obsidian-vault-auto
description: Instantly process any URL, PDF, YouTube link, or file added to the Obsidian inbox. Creates Source → Distilled → Atomic notes, updates MoCs, humanizes prose, and syncs. Triggered when user says "obsidian" followed by a link or file.
version: 1.0.0
trigger: "obsidian"
allowed-tools:
  - Terminal
  - Read
  - Write
  - Glob
  - Grep
---

# Obsidian Vault Auto-Processor

Instantly process any content added to the Obsidian inbox. Triggered when the user says "obsidian" followed by a URL, file path, or link.

## When Triggered

User message contains "obsidian" AND one of:
- A URL (https://...)
- A file path (~/... or /path/to/file)
- A YouTube link (youtube.com, youtu.be)
- A PDF file path

## Vault Path

```
VAULT=~/cvjji9
```

## Workflow

### Step 1: Identify the Input

If the input is a URL:
- Fetch the URL and determine its type (article, blog, PDF link, YouTube, etc.)
- Download to a temporary location if needed

If the input is a file path:
- Verify the file exists
- Determine file type (PDF, markdown, text, etc.)

### Step 2: Create Inbox Entry

For URLs:
- Write the URL to `$VAULT/00-Inbox/raw/` as a `.url` or `.txt` file
- Filename: sanitize the URL title or use a short identifier

For files:
- Copy the file to `$VAULT/00-Inbox/raw/` if not already there

### Step 3: Process Through Pipeline

Use the SAME logic as `process-inbox.sh`:

**For URLs (Defuddle primary, LiteParse fallback):**
```
defuddle parse <url> --md
```
Create:
1. Source note → 01-Sources/
2. Distilled note → 02-Distilled/ (follow DISTILLED_STRUCTURE below)
3. Atomic notes → 03-Atomic/ (follow ATOMIC_RULES below)
4. Update MoCs → 04-MoCs/
5. Archive original → 06-Archive/processed-inbox/

**For PDFs (LiteParse):**
```
lit parse <file> --format text -o /tmp/extracted.md
```
Same pipeline as URLs, but embed the PDF in the Source note.

**For YouTube:**
Fetch transcript via TranscriptAPI (primary) or Supadata (fallback):
```bash
# Primary — TranscriptAPI
curl -s "https://transcriptapi.com/api/v2/youtube/transcript?video_url=$URL&format=text&include_timestamp=true&send_metadata=true" \
  -H "Authorization: Bearer $TRANSCRIPT_API_KEY"

# Fallback — Supadata
curl -s "https://api.supadata.ai/v1/youtube/transcript?url=$URL&text=true&lang=en" \
  -H "x-api-key: $SUPADATA_API_KEY"
```

**For other content:**
Treat as raw content, create notes accordingly.

### Step 4: Humanize All Prose

Before writing ANY content to 02-Distilled/, 03-Atomic/, or 04-MoCs/:
- Run the content through the Humanizer skill
- Write the humanized version

### Step 5: Update MoCs

Search existing MoCs in 04-MoCs/:
- Add wikilinks to new notes in relevant sections
- Create new MoC if topic is substantial enough
- Humanize all MoC prose

### Step 6: Final Sync (CRITICAL)

After ALL processing is complete — including humanizing, MoC updates, and archiving:
```bash
cd $VAULT && ob sync
```
This MUST run before reporting to user. No exceptions.

### Step 7: Report

Tell the user:
- What was processed (URL/file type)
- Where notes were created (Source, Distilled, Atomic count)
- Sync status

## Critical Rules

1. NEVER touch `00-Inbox/quick notes/` — that folder is off-limits
2. ALL prose in Distilled/Atomic/MoC notes MUST be humanized before writing
3. Use [[wikilinks]] for all internal vault links, never markdown links
4. Use Obsidian-flavored markdown (callouts, frontmatter, tags)
5. Source notes go in 01-Sources/, originals archived to 06-Archive/processed-inbox/
6. Follow the DISTILLED_STRUCTURE and ATOMIC_RULES exactly
7. YAML wikilinks in frontmatter MUST be quoted: `source: "[[note]]"`, not `source: [[note]]`

## File Operations

Since obsidian CLI is not available in headless context:
- Create notes by writing .md files directly to vault directory
- Use terminal with cp, mv, cat, mkdir, find, grep
- No `obsidian` CLI commands — use direct file I/O

## DISTILLED_STRUCTURE

```markdown
---
title: "<title>"
source: "[[<Source note>]]"
date_distilled: <YYYY-MM-DD>
tags:
  - distilled
  - <tag1 through tag5-10>
status: review
aliases: []
---

# <title>

## Summary

<3-5 sentence plain-language summary of what this source is about>

## ELI5 insights

### Core insights

<The main findings — as many as the content warrants, not a fixed number.
Plain simple language a non-expert could understand.>

### Other takeaways

<Other important findings. Same ELI5 treatment. No artificial limits.>

## Diagrams

<Mermaid diagrams if content involves processes/relationships/hierarchies.
If nothing warrants a diagram: "N/A">

## Open questions

<Questions, gaps, assumptions raised by the source>

## Linked concepts

<Wikilinks to related Atomic notes, Distilled notes, and MoCs>
```

## ATOMIC_RULES

- One clear, standalone idea per note
- Title = the idea as a concise phrase
- Body = 2-5 sentences, no padding
- Frontmatter: `distilled: "[[<Distilled note>]]"` field required
- Always wikilink back to Source AND Distilled
- Search vault for related existing notes
- ALL prose must be humanized before writing
- References section at bottom:
  ```
  ## References
  - Source: [[<Source note>]]
  - Related: <wikilinks>
  ```
