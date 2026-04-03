#!/usr/bin/env bash
# ============================================================================
# v2: Obsidian Inbox Processor — Karpathy-style LLM Knowledge Base
# Watches raw/ and clippings/, processes each file through
# Defuddle (URLs, primary), LiteParse (fallback), or TranscriptAPI (YouTube),
# creates Source note → Entry note → Concept notes → updates MoCs.
#
# Changes from v1:
#   - Wiki structure: 04-Wiki/entries/, 04-Wiki/concepts/, 04-Wiki/mocs/
#   - Entry notes replace Distilled notes (same body structure, date_entry:)
#   - Concept notes replace Atomic notes (shared vocabulary, not per-source)
#   - Concept convergence: checks existing concepts before creating duplicates
#   - wiki-index.md auto-maintained as retrieval layer
#   - run_with_retry uses set -uo pipefail (NO set -e), manual exit code capture
#
# Supports: Claude Code, Hermes Agent, Codex CLI, or any agentskills.io agent.
# Includes retry logic with exponential backoff.
# Includes idempotency checks and dedup detection.
# ============================================================================

set -uo pipefail

# ═══════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════
VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
LOG_FILE="$VAULT_PATH/Meta/Scripts/processing.log"
LOCK_FILE="/tmp/obsidian-inbox-processor-v2-$(echo "$VAULT_PATH" | md5sum | cut -c1-8).lock"
MAX_RETRIES=3

# Agent command — change for your agent.
# Supported: "claude -p", "codex -p", "hermes run --prompt", etc.
AGENT_CMD="${AGENT_CMD:-claude -p}"

mkdir -p "$VAULT_PATH/Meta/Scripts"

log() { echo "$(date): $1" >> "$LOG_FILE"; }

# ═══════════════════════════════════════════════════════════
# SAFETY: prevent overlapping runs
# ═══════════════════════════════════════════════════════════
if [ -f "$LOCK_FILE" ]; then
  echo "$(date): Another instance is already running. Exiting." >> "$LOG_FILE"
  exit 0
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

# ═══════════════════════════════════════════════════════════
# DEDUP: URL-based idempotency via 06-Config/url-index.tsv
# ═══════════════════════════════════════════════════════════
URL_INDEX="$VAULT_PATH/06-Config/url-index.tsv"
mkdir -p "$(dirname "$URL_INDEX")"
touch "$URL_INDEX"

source_exists_for_url() {
  local url="$1"
  local normalized_url
  normalized_url=$(echo "$url" | sed 's|^https\?://||; s|/$||')
  if grep -qiF "$normalized_url" "$URL_INDEX" 2>/dev/null; then
    return 0
  fi
  return 1
}

register_url_source() {
  local url="$1"
  local source_path="$2"
  local normalized_url
  normalized_url=$(echo "$url" | sed 's|^https\?://||; s|/$||')
  if ! grep -qiF "$normalized_url" "$URL_INDEX" 2>/dev/null; then
    echo -e "${normalized_url}\t${source_path}" >> "$URL_INDEX"
  fi
}

# Build index from existing Source notes if empty
if [ ! -s "$URL_INDEX" ]; then
  for dir in "$VAULT_PATH/01-Sources" "$VAULT_PATH/04-Wiki/sources"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.md; do
      [ -f "$f" ] || continue
      url=$(grep -m1 'source_url:' "$f" 2>/dev/null | sed 's/.*source_url: *//; s/^"//; s/"$//' || true)
      if [ -n "$url" ]; then
        register_url_source "$url" "$f"
      fi
    done
  done
  log "Built URL index from existing sources ($(wc -l < "$URL_INDEX") entries)"
fi

# ═══════════════════════════════════════════════════════════
# RETRY LOGIC — exponential backoff, max 3 attempts
# FIX: set -uo pipefail (NOT set -e), capture exit codes manually
# FIX: static retry advice appended once per retry (not cumulative)
# ═══════════════════════════════════════════════════════════

RETRY_ADVICE="
RETRY CONTEXT: Previous attempt failed. Try alternatives:
- If Defuddle failed, fall back to LiteParse (lit parse <file> --format text).
- If PDF parsing failed, try lit with --no-ocr or different page ranges.
- If TranscriptAPI failed, try bare video ID instead of full URL.
- If a file operation failed, verify the target directory exists (create if needed).
- If rate-limited, use a simpler/shorter prompt.
- If note write failed, write to a temp location first, then mv.
Be resourceful. Find a way."

run_with_retry() {
  local description="$1"
  local prompt="$2"
  local attempt=1
  local delay=5

  while [ $attempt -le $MAX_RETRIES ]; do
    log "Attempt $attempt/$MAX_RETRIES: $description"

    local result=0
    cd "$VAULT_PATH" && $AGENT_CMD "$prompt" 2>> "$LOG_FILE" || result=$?

    if [ $result -eq 0 ]; then
      log "SUCCESS: $description"
      return 0
    fi

    log "FAILED (exit $result): $description — attempt $attempt/$MAX_RETRIES"

    if [ $attempt -lt $MAX_RETRIES ]; then
      log "Waiting ${delay}s before retry (exponential backoff)..."
      sleep $delay
      delay=$((delay * 2))
      prompt="${prompt}${RETRY_ADVICE}"
    fi

    attempt=$((attempt + 1))
  done

  log "GIVING UP after $MAX_RETRIES attempts: $description"
  local file_arg
  file_arg=$(echo "$description" | sed -n 's/.*file: //p' || true)
  if [ -n "$file_arg" ] && [ -f "$file_arg" ]; then
    # v2: use 08-Archive-Raw/failed for any file that comes from raw/ or clippings/
    # v1 compat: also check 00-Inbox for legacy vaults
    if echo "$file_arg" | grep -q "00-Inbox"; then
      mkdir -p "$VAULT_PATH/00-Inbox/failed"
      mv "$file_arg" "$VAULT_PATH/00-Inbox/failed/" 2>/dev/null || true
    else
      mkdir -p "$VAULT_PATH/08-Archive-Raw/failed"
      mv "$file_arg" "$VAULT_PATH/08-Archive-Raw/failed/" 2>/dev/null || true
    fi
    log "Moved failed file to failed archive"
  fi
  return 1
}

# ═══════════════════════════════════════════════════════════
# FILE TYPE DETECTION (same as v1)
# ═══════════════════════════════════════════════════════════
is_url_file() {
  local file="$1"
  local ext="${file##*.}"
  if [[ "$ext" == "url" ]]; then return 0; fi
  if [[ "$ext" == "md" || "$ext" == "txt" ]]; then
    local content
    content=$(cat "$file" | tr -d '[:space:]')
    if [[ "$content" =~ ^https?:// ]]; then return 0; fi
  fi
  return 1
}

is_pdf_file() {
  [[ "${1##*.}" =~ ^[Pp][Dd][Ff]$ ]]
}

is_youtube_link() {
  local file="$1"
  local line_count
  line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
  [ "$line_count" -gt 3 ] && return 1
  local content
  content=$(cat "$file" 2>/dev/null | tr -d '[:space:]')
  [[ "$content" =~ ^https?://(www\.)?(youtube\.com|youtu\.be)/ ]]
}

extract_url_from_file() {
  local file="$1"
  head -1 "$file" | tr -d '[:space:]' | grep -oE 'https?://[^[:space:]]+' || true
}

# ═══════════════════════════════════════════════════════════
# SHARED PROMPT INSTRUCTIONS
# ═══════════════════════════════════════════════════════════
COMMON_INSTRUCTIONS="
VAULT LOCATION: $VAULT_PATH
VAULT STRUCTURE (v2):
  01-Raw/             — New sources to process (URLs, PDFs, files)
  02-Clippings/       — Web clipper saves (already markdown)
  03-Queries/         — Q&A questions (drop .md files here)
  04-Wiki/
  ├── sources/    — Source notes (full original content)
  ├── entries/    — Entry notes (summary + ELI5 + concepts + links)
  ├── concepts/   — Shared concept notes (cross-source vocabulary)
  └── mocs/        — Topic hubs with synthesized summaries
  05-Outputs/         — Q&A responses, visualizations
  06-Config/
  ├── wiki-index.md     — Auto-maintained table of contents
  ├── url-index.tsv     — URL → entry mapping for dedup
  └── tag-registry.md   — Canonical tag list
  07-WIP/               — User drafts (untouched by automation)
  08-Archive-Raw/       — Processed inbox items
  09-Archive-Queries/   — Answered queries

AGENT AVAILABLE: obsidian-markdown, humanizer, youtube-full (TranscriptAPI), liteparse

CRITICAL RULES:
1. NEVER touch anything in '07-WIP/'. Off-limits.
2. ALL AI-generated prose for 04-Wiki/entries/, 04-Wiki/concepts/, or 04-Wiki/mocs/
   MUST be run through the Humanizer skill before writing to disk.
   Draft the content → humanize it → write the final file.
3. Use [[wikilinks]] for all internal vault links.
4. Use Obsidian-flavored markdown (callouts, frontmatter, tags).
5. ALL YAML frontmatter: wikilinks MUST be quoted
   (e.g. source: \"[[note]]\").
6. Entry notes go in '04-Wiki/entries/', Concept notes in '04-Wiki/concepts/',
   MoC notes in '04-Wiki/mocs/'. Processed originals archived to '08-Archive-Raw/'.
7. After creating any Entry or Concept, APPEND a line to
   '06-Config/wiki-index.md' with a 1-sentence summary.

PARSER ROUTING:
- Primary: Use Defuddle for any URLs and applicable file-to-markdown conversions.
- Fallback: If Defuddle fails, fall back to LiteParse:
    lit parse <file> --format text
- YouTube links: Use TranscriptAPI (primary) with Supadata (fallback).
  Primary: curl -s 'https://transcriptapi.com/api/v2/youtube/transcript?video_url=VIDEO_URL&format=text&include_timestamp=false&send_metadata=true'
    -H 'Authorization: Bearer \$TRANSCRIPT_API_KEY'
  Fallback: curl -s 'https://api.supadata.ai/v1/youtube/transcript?url=VIDEO_URL&text=true&lang=en'
    -H 'x-api-key: \$SUPADATA_API_KEY'
  Then convert the transcript to clean markdown.

TAG CONSOLIDATION:
Before creating new tags, ALWAYS search existing tags in the vault first:
  obsidian tags sort=count counts
Reuse existing tags wherever possible. Only mint a new tag if nothing fits.

RETRY BEHAVIOR:
If any step fails (API call, file operation, parsing), try an alternative
approach before giving up. Be resourceful.
"

# ═══════════════════════════════════════════════════════════
# ENTRY NOTE STRUCTURE (strict — preserves user's reading format)
# ═══════════════════════════════════════════════════════════
ENTRY_STRUCTURE="
ENTRY NOTE STRUCTURE — follow EXACTLY for every note in 04-Wiki/entries/:

Frontmatter (YAML) must include:
  - title: "<concise title>"
  - source: "[[<source-note-name>]]"  (MUST be quoted wikilink)
  - date_entry: YYYY-MM-DD
  - status: review
  - aliases: []
  - tags: minimum 5, maximum 10 topic-specific tags, always start with:
      tags:
        - entry
        - topic-tag-1
        - topic-tag-2
        ...

BEFORE choosing tags: run 'obsidian tags sort=count counts' and reuse
existing tags wherever a match exists. Only mint a new tag if nothing fits.

Body sections IN THIS ORDER (use ## and ### markdown headings):

## Summary
3-5 sentence summary of what the source is about. Plain language, no fluff.

## ELI5 insights

### Core insights
Main findings explained like to a smart 12-year-old. Simple language,
no jargon, concrete examples. Use a numbered list (1., 2., 3., etc.).
Extract EVERYTHING significant. Not top 5 or top 10 — as many as exist.
Each numbered item is substantive with a clear ELI5 explanation.

### Other takeaways
Other important findings. Same ELI5 treatment. Use a numbered list that
CONTINUES from Core insights numbering (e.g., if Core ends at 4, start
Other at 5). No artificial limits.

## Diagrams
If the content involves processes, relationships, hierarchies, comparisons,
or any concept that would be clearer as a visual: include a Mermaid diagram
using Obsidian's native mermaid code block support.
If no diagram would genuinely help, write: 'N/A — content is straightforward.'

## Open questions
Use a numbered list (1., 2., 3.). Questions, gaps, assumptions raised by
the source. What doesn't the source answer? What assumptions does it make?

## Linked concepts
Use a bullet-point list (dash-prefixed). Wikilinks to related Concept notes,
other Entry notes, and MoCs.
Use 'obsidian search' to find existing related notes in the vault.
Link to concepts in 04-Wiki/concepts/, entries in 04-Wiki/entries/, and MoCs in 04-Wiki/mocs/.

CONCEPT NOTE STRUCTURE for 04-Wiki/concepts/:
- Concept notes are the wiki's vocabulary — shared across all Entries.
- One clear, standalone idea per note.
- CONCEPT CONVERGENCE (MANDATORY): Before creating a new concept, search
  04-Wiki/concepts/ for existing concepts that cover the same idea.
  - If found: UPDATE the existing concept — add this Entry to its
    entry_refs, update the body if needed. Do NOT create a duplicate.
  - If a near-duplicate exists (same concept split into two notes): MERGE
    them into the older note, add all entry_refs, and delete the newer one.
  - Only create a brand-new concept if the idea is truly novel.

Frontmatter must include:
  - title: \"<concept name as concise phrase>\"
  - date_created: YYYY-MM-DD
  - updated: YYYY-MM-DD
  - status: evergreen (change to seed if uncertain)
  - aliases: []
  - entry_refs: (list of wikilinks to Entry notes, quoted)
      entry_refs:
        - \"[[Entry name 1]]\"
        - \"[[Entry name 2]]\"
  - tags: minimum 2, maximum 5 topic-specific tags (not counting 'concept')

Body:
  # <Concept Name>

  <2-5 sentences explaining the idea standalone. Clear, humanized prose.>

  ## References
  - Entries: [[Entry1]], [[Entry2]]
  - Related Concepts: [[Concept1]], [[Concept2]] (search for these)

ALL prose must be humanized before writing.
"

# ═══════════════════════════════════════════════════════════
# MoC NOTE STRUCTURE (v2)
# ═══════════════════════════════════════════════════════════
MOC_STRUCTURE="
MOC NOTE STRUCTURE — for 04-Wiki/mocs/:

Frontmatter:
  - title: \\"<Topic Name> — Map of Content\\"
  - type: moc
  - status: active
  - date_created: YYYY-MM-DD
  - date_updated: YYYY-MM-DD
  - tags: the topic tag repeated, plus 'map-of-content'

Body:
  # <Topic Name> — Map of Content

  ## Overview
  <2-3 sentence synthesized summary of this topic. Explain WHAT this topic
  covers and WHY it matters. Prose paragraph for at-a-glance understanding.>

  ## Core Concepts
  - [[<Concept note>]] — <1-sentence summary>

  ## Related Entries
  - [[<Entry note>]] — <1-sentence summary>

  ## Open Threads
  - <Questions that remain unanswered, for future exploration>

  ## Notes
  <Optional deeper commentary about the state of knowledge on this topic.>

ALL MoC prose must be humanized before writing.
"

# ═══════════════════════════════════════════════════════════
# PROCESS: YouTube links (TranscriptAPI → Entry + Concepts)
# ═══════════════════════════════════════════════════════════
process_youtube() {
  local file="$1"
  local url
  url=$(cat "$file" | tr -d '[:space:]')

  if source_exists_for_url "$url"; then
    log "SKIP (duplicate): YouTube — file: $file"
    mkdir -p "$VAULT_PATH/08-Archive-Raw"
    mv "$file" "$VAULT_PATH/08-Archive-Raw/" 2>/dev/null || true
    return 0
  fi

  run_with_retry "YouTube — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a YouTube video link into the wiki.
FILE: '$file'
URL: $url

STEP 1 — FETCH TRANSCRIPT
Use TranscriptAPI as PRIMARY, Supadata as FALLBACK.

**Primary — TranscriptAPI (\$TRANSCRIPT_API_KEY):**
  curl -s 'https://transcriptapi.com/api/v2/youtube/transcript?video_url=$url&format=text&include_timestamp=false&send_metadata=true' \\
    -H 'Authorization: Bearer \$TRANSCRIPT_API_KEY'

**Fallback — Supadata (\$SUPADATA_API_KEY):**
  curl -s 'https://api.supadata.ai/v1/youtube/transcript?url=$url&text=true&lang=en' \\
    -H 'x-api-key: \$SUPADATA_API_KEY'

If BOTH fail, create Source note with URL and status: needs-transcript.

Convert transcript to clean markdown paragraphs.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '04-Wiki/sources/' with:
  - YouTube URL, video title, channel name
  - Full transcript as markdown in 'Original content' section
  - Frontmatter: title, source_url, source_type: youtube, author, tags, status: processed

STEP 3 — CREATE ENTRY NOTE
$ENTRY_STRUCTURE
Draft the full Entry note from the transcript.
Humanize all prose, then write to '04-Wiki/entries/'.
IMPORTANT: Use date_entry: (NOT date_distilled:) in frontmatter.

STEP 4 — CREATE/UPDATE CONCEPT NOTES
$CONCEPT_STRUCTURE
MANDATORY: Search 04-Wiki/concepts/ BEFORE creating any new concept.
Check if existing concepts cover the same idea. If yes, UPDATE existing
concept (add entry_ref, refresh body if needed). Only create new if truly novel.
Humanize all concept prose before writing.

STEP 5 — UPDATE MoCs
Search 04-Wiki/mocs/ for relevant topic matches. For each matching or new MoC:
- Add wikilinks with 1-sentence summaries for new Entry and Concept notes
- Humanize all MoC prose

STEP 6 — UPDATE WIKI INDEX
Append the new Entry and any new Concepts to '06-Config/wiki-index.md'
with 1-sentence summaries in this format:
  - [[EntryName]]: <1-sentence summary> (entry)
  - [[ConceptName]]: <1-sentence summary> (concept)

STEP 7 — ARCHIVE
Move original inbox file to '08-Archive-Raw/'.
Register URL in the index: append '\$url\t<source-note-path>' to '$URL_INDEX'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: URLs (Defuddle primary → LiteParse fallback)
# ═══════════════════════════════════════════════════════════
process_url() {
  local file="$1"
  local url
  url=$(cat "$file" | tr -d '[:space:]')

  if source_exists_for_url "$url"; then
    log "SKIP (duplicate): URL — file: $file"
    mkdir -p "$VAULT_PATH/08-Archive-Raw"
    mv "$file" "$VAULT_PATH/08-Archive-Raw/" 2>/dev/null || true
    return 0
  fi

  run_with_retry "URL — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a URL from the inbox into the wiki.
FILE: '$file'
URL: $url

STEP 1 — EXTRACT CONTENT
Use Defuddle as PRIMARY:
  defuddle parse '$url' --md
If Defuddle fails or returns empty/unusable content, FALL BACK to LiteParse:
  Download the page, then: lit parse <downloaded_file> --format text
If both fail, create minimal Source note with URL and mark
status: needs-manual-extraction.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '04-Wiki/sources/' with extracted markdown.
Frontmatter: title, source_url, source_type, author, date_captured, tags, status: processed.
IMPORTANT: Wikilinks in YAML frontmatter MUST be quoted.

STEP 3 — CREATE ENTRY NOTE
$ENTRY_STRUCTURE
Draft the full Entry note. Humanize all prose, write to '04-Wiki/entries/'.
IMPORTANT: Use date_entry: (NOT date_distilled:) in frontmatter.

STEP 4 — CREATE/UPDATE CONCEPT NOTES
$CONCEPT_STRUCTURE
MANDATORY: Search 04-Wiki/concepts/ BEFORE creating any new concept.
Check for existing concepts covering the same idea. Update existing or
merge near-duplicates. Only create new if truly novel.
Humanize all prose.

STEP 5 — UPDATE MoCs
Search 04-Wiki/mocs/ for matching topics. Add wikilinks with 1-sentence
summaries for new Entry and Concept notes. Humanize MoC prose.

STEP 6 — UPDATE WIKI INDEX
Append new Entry and Concepts to '06-Config/wiki-index.md':
  - [[EntryName]]: <1-sentence summary> (entry)
  - [[ConceptName]]: <1-sentence summary> (concept)

STEP 7 — ARCHIVE
Move original inbox file to '08-Archive-Raw/'.
Register URL in the index: append '\$url\t<source-note-path>' to '$URL_INDEX'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: PDFs and other files
# ═══════════════════════════════════════════════════════════
process_file() {
  local file="$1"
  local filename
  filename=$(basename "$file")
  local name_no_ext="${filename%.*}"

  run_with_retry "File — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a file from the inbox into the wiki.
FILE: '$file'
FILENAME: '$filename'

STEP 1 — EXTRACT CONTENT
Try Defuddle first if applicable:
  defuddle parse '$file' --md
If Defuddle can't handle this file type, FALL BACK to LiteParse:
  lit parse '$file' --format text -o '/tmp/${name_no_ext}_extracted.md'
LiteParse handles PDFs, DOCX, PPTX, XLSX, images (with OCR), and more.
Read the extracted text output.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '04-Wiki/sources/' with:
  - If PDF: keep reference to original, embed as needed
  - Include extracted text in 'Original content' section
  - Frontmatter: title, author, source_type, tags, status: processed
  - IMPORTANT: Wikilinks in YAML frontmatter MUST be quoted

STEP 3 — CREATE ENTRY NOTE
$ENTRY_STRUCTURE
Draft the full Entry note. Humanize all prose, write to '04-Wiki/entries/'.
IMPORTANT: Use date_entry: (NOT date_distilled:) in frontmatter.

STEP 4 — CREATE/UPDATE CONCEPT NOTES
$CONCEPT_STRUCTURE
MANDATORY: Search 04-Wiki/concepts/ BEFORE creating any new concept.
Check for existing concepts covering the same idea. Update existing or
merge near-duplicates. Only create new if truly novel.
Humanize all prose.

STEP 5 — UPDATE MoCs
Search 04-Wiki/mocs/ for matching topics. Add wikilinks with 1-sentence
summaries. Humanize MoC prose.

STEP 6 — UPDATE WIKI INDEX
Append new Entry and Concepts to '06-Config/wiki-index.md'.

STEP 7 — ARCHIVE
Move the original file to '08-Archive-Raw/'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: Clippings (already markdown)
# ═══════════════════════════════════════════════════════════
process_clipping() {
  local file="$1"
  local source_url
  source_url=$(grep -m1 'source_url:' "$file" 2>/dev/null | sed 's/.*source_url: *//; s/^"//; s/"$//' || true)

  if [ -n "$source_url" ] && source_exists_for_url "$source_url"; then
    log "SKIP (duplicate): Clipping — file: $file"
    mkdir -p "$VAULT_PATH/08-Archive-Raw"
    mv "$file" "$VAULT_PATH/08-Archive-Raw/" 2>/dev/null || true
    return 0
  fi

  run_with_retry "Clipping — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a web clipper save into the wiki.
FILE: '$file'

The file likely contains markdown captured by Obsidian Web Clipper,
possibly with frontmatter (source_url, title).

STEP 1 — CREATE SOURCE NOTE
Extract source_url from frontmatter if present.
If it has a source_url and no Source for this URL exists, create a
Source note in '04-Wiki/sources/'. If a Source already exists for this URL,
skip Source creation (do not duplicate).

STEP 2 — CREATE ENTRY NOTE
$ENTRY_STRUCTURE
Draft the full Entry note. Humanize all prose, write to '04-Wiki/entries/'.
IMPORTANT: Use date_entry: (NOT date_distilled:) in frontmatter.

STEP 3 — CREATE/UPDATE CONCEPT NOTES
$CONCEPT_STRUCTURE
MANDATORY: Search 04-Wiki/concepts/ BEFORE creating any new concept.
Check for existing concepts covering the same idea. Update existing or
merge near-duplicates. Only create new if truly novel.
Humanize all prose.

STEP 4 — UPDATE MoCs
Search 04-Wiki/mocs/ for matching topics. Add wikilinks with 1-sentence
summaries. Humanize MoC prose.

STEP 5 — UPDATE WIKI INDEX
Append new Entry and Concepts to '06-Config/wiki-index.md'.

STEP 6 — ARCHIVE
Move the clipping to '08-Archive-Raw/'.
If the clipping had a source_url, register it in '$URL_INDEX'.
"
}

# ═══════════════════════════════════════════════════════════
# MAIN LOOP — processes raw/ and clippings/
# NEVER touches 07-WIP/
# ═══════════════════════════════════════════════════════════
setup_directory_structure() {
  mkdir -p "$VAULT_PATH/01-Raw"
  mkdir -p "$VAULT_PATH/02-Clippings"
  mkdir -p "$VAULT_PATH/03-Queries"
  mkdir -p "$VAULT_PATH/04-Wiki/entries"
  mkdir -p "$VAULT_PATH/04-Wiki/concepts"
  mkdir -p "$VAULT_PATH/04-Wiki/mocs"
  mkdir -p "$VAULT_PATH/04-Wiki/sources"
  mkdir -p "$VAULT_PATH/05-Outputs/answers"
  mkdir -p "$VAULT_PATH/05-Outputs/visualizations"
  mkdir -p "$VAULT_PATH/06-Config"
  mkdir -p "$VAULT_PATH/07-WIP"
  mkdir -p "$VAULT_PATH/08-Archive-Raw"
  mkdir -p "$VAULT_PATH/09-Archive-Queries"

  # Initialize wiki-index.md if it doesn't exist
  if [ ! -f "$VAULT_PATH/06-Config/wiki-index.md" ]; then
    cat > "$VAULT_PATH/06-Config/wiki-index.md" << 'HEADER'
# Wiki Index

Auto-maintained table of contents for the knowledge base.
Each entry and concept has a 1-sentence summary for retrieval.
This index is the primary retrieval layer — the LLM reads this
to find relevant notes instead of using RAG.

---

HEADER
  fi

  # Initialize tag-registry.md if it doesn't exist
  if [ ! -f "$VAULT_PATH/06-Config/tag-registry.md" ]; then
    cat > "$VAULT_PATH/06-Config/tag-registry.md" << 'HEADER'
# Tag Registry

Canonical list of tags used in this wiki. Before minting a new tag,
check this registry and prefer reuse.

## Entry Tags


## Concept Tags


HEADER
  fi
}

# Main loop — processes 01-Raw/
# NEVER touches 07-WIP/
setup_directory_structure

processed=0
skipped=0
failed=0

# Process everything in 01-Raw/
if [ -d "$VAULT_PATH/01-Raw" ]; then
  for file in "$VAULT_PATH/01-Raw"/*; do
    [ -f "$file" ] || continue

    if is_youtube_link "$file"; then
      process_youtube "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
    elif is_url_file "$file"; then
      process_url "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
    else
      process_file "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
    fi
  done
fi

# Process everything in 02-Clippings/
if [ -d "$VAULT_PATH/02-Clippings" ]; then
  for file in "$VAULT_PATH/02-Clippings"/*.md; do
    [ -f "$file" ] || continue
    process_clipping "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
  done
fi

log "Inbox processing complete (v2). Processed: $processed, Failed: $failed"
log "URL index now has $(wc -l < "$URL_INDEX") entries"
