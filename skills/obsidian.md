---
name: obsidian
description: "Process any URL, file, or link into the Obsidian knowledge vault. Drop it in the inbox, process through the wiki pipeline, report results. Handles YouTube, podcasts, articles, PDFs, and files."
version: 2.2.0
trigger: "obsidian"
---

# Obsidian Vault Processor

Instantly process any content into the wiki knowledge base. Triggered when the user says "obsidian" followed by a URL, file path, or link.

## When Triggered

User message contains "obsidian" AND one of:
- A URL (https://...)
- A file path (~/... or /path/to/file)
- A YouTube link (youtube.com, youtu.be)
- A podcast link (Apple Podcasts, Spotify, Anchor, etc.)
- A PDF or document file path

## Configuration

```bash
VAULT_PATH="${OBSIDIAN_VAULT:-$HOME/MyVault}"
```

User can override with: `export OBSIDIAN_VAULT="/path/to/vault"`

## Input Type Detection

Detect the input type to route to the right handler:

| Input | Type | Handler |
|---|---|---|
| `youtube.com/watch?v=...`, `youtu.be/...` | YouTube | process_youtube (TranscriptAPI) |
| `podcasts.apple.com`, `open.spotify.com`, `.mp3`, `.rss` | Podcast | process_podcast (AssemblyAI) |
| `https://...` (any other URL) | Article/URL | process_url (Defuddle) |
| `.pdf` file path | PDF | process_file (LiteParse) |
| `.md`, `.txt`, or other file | File | process_file (LiteParse) |

## Workflow

### Step 1: Identify Input and Write to Inbox

**For URLs:**
```bash
# Determine filename from URL (sanitized)
FILENAME=$(echo "$URL" | sed 's|https\?://||;s|[^a-zA-Z0-9._-]|_|g' | head -c 80)
echo "$URL" > "$VAULT_PATH/01-Raw/${FILENAME}.url"
```

**For files:**
```bash
# Copy to inbox
cp "$FILE_PATH" "$VAULT_PATH/01-Raw/"
```

### Step 2: Run Process Inbox

```bash
VAULT_PATH="$VAULT_PATH" bash "$VAULT_PATH/Meta/Scripts/process-inbox.sh"
```

Or if running from the repo:
```bash
VAULT_PATH="$VAULT_PATH" bash scripts/process-inbox.sh
```

### Step 3: Report Results

Tell the user:
- What was processed (type, title)
- Where notes were created (Entry name, Concepts created, MoCs updated)
- Review status (all notes start as `reviewed: null`)
- Any errors or skips

## Direct Processing (No Inbox)

If the user wants immediate processing without waiting for batch mode, the agent can process directly:

1. Source the libraries:
```bash
source lib/common.sh
source lib/transcribe.sh
```

2. Detect type and process inline using the appropriate function from process-inbox.sh.

## Supported Platforms

### YouTube
- Full URLs: `https://youtube.com/watch?v=ID`
- Short URLs: `https://youtu.be/ID`
- Transcript via TranscriptAPI (primary) or Supadata (fallback)

### Podcasts
- Apple Podcasts: `https://podcasts.apple.com/...`
- Spotify: `https://open.spotify.com/episode/...`
- Direct MP3: `https://example.com/episode.mp3`
- RSS feeds: `https://feeds.example.com/show.rss`
- Anchor, Buzzsprout, Libsyn, Podbean, SoundCloud, etc.
- Transcription via AssemblyAI (primary) or local whisper (fallback)

### Articles/Web
- Any `https://...` URL not matching YouTube or podcast patterns
- Content extraction via Defuddle (primary) or LiteParse (fallback)

### Arxiv Papers (special handling)
- arxiv.org/abs/ID → rewrite to arxiv.org/html/IDv1, extract with defuddle (~100K chars full text)
- Fallback: alphaxiv.org/abs/ID.md (full text) or alphaxiv.org/overview/ID.md (summary)
- Never extract just the abstract page — always go for HTML or alphaxiv

### X/Twitter
- Articles (long-form): defuddle handles them (~10-30K chars)
- Regular tweets: defuddle may return minimal content, acceptable for short takes

### Medium / Cloudflare-protected sites
- Defuddle returns 403 on Medium. Fallback to Tavily extract.
- Some academic publishers (akjournals, springer) also block — try PDF download + liteparse

### Files
- PDF: extracted via LiteParse
- Markdown: processed as-is
- Text: processed as-is
- Other: attempted via LiteParse

## Example Invocations

```
obsidian https://www.youtube.com/watch?v=abc123
obsidian https://podcasts.apple.com/us/podcast/show/id123456
obsidian https://blog.example.com/great-article
obsidian ~/Downloads/research-paper.pdf
obsidian ~/notes/meeting-notes.md
```

## Critical Rules

1. NEVER touch `07-WIP/` — user territory
2. NEVER overwrite existing notes — check_collision() first
3. ALL prose must be humanized before writing to wiki
4. YAML wikilinks MUST be quoted: `source: "[[note]]"`
5. Use [[wikilinks]] for all internal vault links
6. Log every operation to `06-Config/log.md`
7. Source/Entry filenames MUST use clean human-readable titles, NOT URL slugs
   - ✅ `the-measles-market-on-kalshi-settlement-coin-flip.md`
   - ❌ `www.oddchain.com_p_the-measles-market-on-kalshi-for-2025-is-one-of-the-dumbest-a.md`
   - Use `clean_title()` from common.sh to extract title from content

## Troubleshooting

- **"ASSEMBLYAI_API_KEY not set"**: Set `export ASSEMBLYAI_API_KEY="***"` for podcast processing
- **"defuddle not found"**: Install with `npm install -g defuddle`
- **"lit not found"**: Install with `npm install -g @llamaindex/liteparse`
- **URL already processed**: Check `06-Config/url-index.tsv` for dedup — the system skips known URLs
- **Large podcast timeout**: AssemblyAI has a 10-minute poll limit. Very long episodes (>2hrs) may need manual retry
- **"common.sh not found" when sourced from scripts/**: SCRIPT_DIR inheritance bug. In extract.sh, use `_EXTRACT_DIR` not `SCRIPT_DIR` (which gets set by the parent script)
- **Lock file blocks new run**: Remove `/tmp/obsidian-process-inbox-*.lock` before restarting. Stale locks from killed processes persist.
