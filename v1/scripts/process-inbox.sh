#!/usr/bin/env bash
# ============================================================================
# Obsidian Inbox Processor — Agent-agnostic + headless file operations
# Watches 00-Inbox/raw/ and 00-Inbox/clippings/, processes each file through
# Defuddle (URLs, primary), LiteParse (fallback), or TranscriptAPI (YouTube),
# creates Source → Distilled → Atomic notes, humanizes AI prose, updates MoCs.
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
mkdir -p "$VAULT_PATH/Meta/Scripts"
LOG_FILE="$VAULT_PATH/Meta/Scripts/processing.log"
LOCK_FILE="/tmp/obsidian-inbox-processor-$(echo "$VAULT_PATH" | md5sum | cut -c1-8).lock"
MAX_RETRIES=3

# Agent command — change for your agent.
# Supported values and what they do:
#   "claude"              — Claude Code interactive (full tool execution + streaming)
#   "claude -p"           — Claude Code print-mode (tool execution, prints final answer)
#   "codex -p"            — Codex CLI print-mode (non-interactive, executes tools)
#   "hermes run --prompt" — Hermes Agent prompt mode
#
# IMPORTANT: Do NOT use interactive-mode agents in cron. Use -p / --prompt variants.
# For manual runs, plain "claude" is fine.
AGENT_CMD="${AGENT_CMD:-claude -p}"

# ═══════════════════════════════════════════════════════════
# SAFETY: prevent overlapping runs
# ═══════════════════════════════════════════════════════════
if [ -f "$LOCK_FILE" ]; then
  echo "$(date): Another instance running. Exiting." >> "$LOG_FILE"
  exit 0
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

log() { echo "$(date): $1" >> "$LOG_FILE"; }

# ═══════════════════════════════════════════════════════════
# DEDUP: Check if a Source note already exists for a URL
# Uses a URL index file: Meta/Scripts/url-index.tsv (url \t path)
# ═══════════════════════════════════════════════════════════
URL_INDEX="$VAULT_PATH/Meta/Scripts/url-index.tsv"
touch "$URL_INDEX"

source_exists_for_url() {
  local url="$1"
  local normalized_url
  # Strip protocol and trailing slash for comparison
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
  # Only register if not already in index
  if ! grep -qiF "$normalized_url" "$URL_INDEX" 2>/dev/null; then
    echo -e "${normalized_url}\t${source_path}" >> "$URL_INDEX"
  fi
}

# Build index from existing sources if empty
if [ ! -s "$URL_INDEX" ]; then
  # Extract source_url from frontmatter of existing Source notes
  if [ -d "$VAULT_PATH/01-Sources" ]; then
    for f in "$VAULT_PATH/01-Sources"/*.md; do
      [ -f "$f" ] || continue
      url=$(grep -m1 'source_url:' "$f" 2>/dev/null | sed 's/.*source_url: *//; s/^"//; s/"$//' || true)
      if [ -n "$url" ]; then
        register_url_source "$url" "$f"
      fi
    done
    log "Built URL index from existing sources ($(wc -l < "$URL_INDEX") entries)"
  fi
fi

# ═══════════════════════════════════════════════════════════
# RETRY LOGIC — exponential backoff, max 3 attempts
# FIX: Don't use set -e; capture exit codes manually
# FIX: Don't let prompt grow unboundedly on retries
# ═══════════════════════════════════════════════════════════

# Static retry advice — appended once per retry without re-accumulating
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
  local delay=5  # initial delay in seconds

  while [ $attempt -le $MAX_RETRIES ]; do
    log "Attempt $attempt/$MAX_RETRIES: $description"

    local agent_exit=0
    cd "$VAULT_PATH" && $AGENT_CMD "$prompt" 2>> "$LOG_FILE" || agent_exit=$?

    if [ $agent_exit -eq 0 ]; then
      log "SUCCESS: $description"
      return 0
    fi

    log "FAILED (exit $agent_exit): $description — attempt $attempt/$MAX_RETRIES"

    if [ $attempt -lt $MAX_RETRIES ]; then
      log "Waiting ${delay}s before retry (exponential backoff)..."
      sleep $delay
      delay=$((delay * 2))

      # Append static retry advice — NOT cumulative (appended only once)
      prompt="${prompt}${RETRY_ADVICE}"
    fi

    attempt=$((attempt + 1))
  done

  log "GIVING UP after $MAX_RETRIES attempts: $description"
  # Move the failed file to a failed/ subfolder for manual review
  local file_arg
  file_arg=$(echo "$description" | sed -n 's/.*file: //p' || true)
  if [ -n "$file_arg" ] && [ -f "$file_arg" ]; then
    mkdir -p "$VAULT_PATH/00-Inbox/failed"
    mv "$file_arg" "$VAULT_PATH/00-Inbox/failed/" 2>/dev/null || true
    log "Moved failed file to 00-Inbox/failed/"
  fi
  return 1
}

# ═══════════════════════════════════════════════════════════
# FILE TYPE DETECTION
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
  # Only treat single-line URL files as YouTube links, not mixed-content notes
  local line_count
  line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
  [ "$line_count" -gt 3 ] && return 1
  local content
  content=$(cat "$file" 2>/dev/null | tr -d '[:space:]')
  [[ "$content" =~ ^https?://(www\.)?(youtube\.com|youtu\.be)/ ]]
}

is_podcast_file() {
  local file="$1"
  # Check if file is an audio file or contains podcast indicators
  [[ "${1##*.}" =~ ^(mp3|m4a|ogg|wav|flac|aac)$ ]] && return 0
  
  # Check if file contains podcast-related keywords
  local content
  content=$(cat "$file" 2>/dev/null)
  [[ "$content" =~ (podcast|episode|\.mp3|\.m4a|rss\.feeds) ]] && return 0
  
  return 1
}

# Extract URL from an inbox file
extract_url_from_file() {
  local file="$1"
  local content
  content=$(cat "$file" | head -1 | tr -d '[:space:]')
  echo "$content" | grep -oE 'https?://[^[:space:]]+' || true
}

# ═══════════════════════════════════════════════════════════
# SHARED PROMPT INSTRUCTIONS
# FIX: Use proper env var names, not truncated cosmetic placeholders
# ═══════════════════════════════════════════════════════════
COMMON_INSTRUCTIONS="
VAULT LOCATION: $VAULT_PATH
AGENT AVAILABLE: obsidian-markdown, humanizer, youtube-full (TranscriptAPI), liteparse

CRITICAL RULES:
1. NEVER touch anything in '00-Inbox/quick notes/'. Off-limits.
2. ALL AI-generated prose for 02-Distilled/, 03-Atomic/, or 04-MoCs/
   MUST be run through the Humanizer skill before writing to disk.
   Draft the content → humanize it → write the final file.
3. Use [[wikilinks]] for all internal vault links.
4. Use Obsidian-flavored markdown (callouts, frontmatter, tags).
5. Use obsidian CLI where helpful:
   obsidian create, obsidian search, obsidian append, obsidian property:set
6. Source notes go in '01-Sources/'. Processed originals go to '06-Archive/processed-inbox/'.

PARSER ROUTING:
- Primary: Use Defuddle for any URLs and applicable file-to-markdown conversions.
- Fallback: If Defuddle fails, fall back to LiteParse:
    lit parse <file> --format text
YouTube links: Use full hierarchy: existing → TranscriptAPI → Supadata → local Whisper.
  Primary: curl -s 'https://transcriptapi.com/api/v2/youtube/transcript?video_url=VIDEO_URL&format=text&include_timestamp=false&send_metadata=true'
    -H 'Authorization: Bearer \$TRAN...KEY'
  Fallback 1: curl -s 'https://api.supadata.ai/v1/youtube/transcript?url=VIDEO_URL&text=true&lang=en'
    -H 'x-api-key: \$SUPADATA_API_KEY'
  Fallback 2 (last resort): yt-dlp + local Whisper
    yt-dlp -x --audio-format mp3 -o "/tmp/%(id)s.%(ext)s" VIDEO_URL
    whisper "/tmp/VIDEO_ID.mp3" --model medium --language en --output_format txt
  Then convert the transcript to clean markdown.

Podcast links: Check for existing transcript, then use AssemblyAI.
  Check RSS feed show notes, podcast website, or existing vault notes first.
  Fallback: Upload audio to AssemblyAI for transcription with speaker labels.

TAG CONSOLIDATION:
Before creating new tags, ALWAYS search existing tags in the vault first:
  obsidian tags sort=count counts
Reuse existing tags wherever possible. Only mint a new tag if nothing fits.
This prevents tag sprawl and keeps the taxonomy clean.

RETRY BEHAVIOR:
If any step fails (API call, file operation, parsing), try an alternative
approach before giving up. Be resourceful.
"

# ═══════════════════════════════════════════════════════════
# DISTILLED NOTE STRUCTURE (strict)
# ═══════════════════════════════════════════════════════════
DISTILLED_STRUCTURE="
DISTILLED NOTE STRUCTURE — follow EXACTLY for every note in 02-Distilled/:

Frontmatter must include:
  - title, source (quoted wikilink — YAML interprets [[ as list, so ALWAYS quote),
    date_distilled, status: review
    Example:  source: \"[[my-source-note]]\"
  - tags: minimum 5, maximum 10 topic-specific tags (not counting 'distilled')
  - BEFORE choosing tags: run 'obsidian tags sort=count counts' and reuse
    existing tags wherever a match exists. Only mint a new tag if nothing fits.

Body sections IN THIS ORDER:

## Summary
3-5 sentence summary of what the source is about. Plain language, no fluff.

## ELI5 insights

### Core insights
The main, most important findings. Explain each one as if to a smart
12-year-old — simple language, no jargon, concrete examples where possible.
Extract EVERYTHING significant. Not top 5, not top 10 — as many as exist.
Each bullet should be a substantive point with a clear ELI5 explanation.

### Other takeaways
Other findings that are deemed important but not core. Same ELI5 treatment.
Again, extract as many as the content warrants. No artificial limits.

## Diagrams
If the content involves processes, relationships, hierarchies, comparisons,
or any concept that would be clearer as a visual: include a Mermaid diagram,
mindmap, or flowchart using Obsidian's native mermaid code block support.
If no diagram would genuinely help, write 'N/A — content is straightforward.'

## Open questions
Questions, issues, or gaps raised by this content that are worth thinking
about further. What doesn't the source answer? What assumptions does it make?

## Linked concepts
Wikilinks to related Atomic notes, other Distilled notes, and MoCs.
Use 'obsidian search' to find existing related notes in the vault.
"

# ═══════════════════════════════════════════════════════════
# ATOMIC NOTE RULES
# ═══════════════════════════════════════════════════════════
ATOMIC_RULES="
ATOMIC NOTE RULES for 03-Atomic/:
- One clear, standalone idea per note.
- Title = the idea expressed as a concise phrase.
- Body = 2-5 sentences explaining the idea. No padding.
- Frontmatter tags: minimum 2, maximum 5 topic-specific tags
  (not counting 'atomic').
- BEFORE choosing tags: run 'obsidian tags sort=count counts' and reuse
  existing tags. Only create new tags if nothing fits.
- Always include a wikilink back to the Source and Distilled notes.
- Search the vault for related Atomic notes and add wikilinks.
- ALL prose must be humanized before writing.
"

# ═══════════════════════════════════════════════════════════
# MoC NOTE STRUCTURE (includes auto-summary)
# NEW: MoCs now include synthesized summaries, not just link lists
# ═══════════════════════════════════════════════════════════
MOC_STRUCTURE="
MOC NOTE STRUCTURE — for 04-MoCs/:

Frontmatter:
  - title, type: moc, status: active, created, updated
  - tags: the topic tag repeated, plus 'map-of-content'

Body:
# <Topic Name> — Map of Content

## Overview
<2-3 sentence synthesized summary of this topic. Explain WHAT this topic
covers and WHY it matters. This is not a list — it's a prose paragraph
that would help someone understand the topic at a glance.>

## Core Concepts
- [[<Atomic note>]] — <1-sentence summary of the note>
(one line per Atomic note with a brief summary, not just a wikilink)

## Related Research
- [[<Distilled note>]] — <1-sentence summary>

## Open Threads
- <Questions that remain unanswered, for future exploration>

## Notes
<Optional deeper commentary about the state of knowledge on this topic.>
"

# ═══════════════════════════════════════════════════════════
# PROCESS: YouTube links (TranscriptAPI → markdown)
# NEW: Checks for existing source before processing
# ═══════════════════════════════════════════════════════════
process_youtube() {
  local file="$1"
  local url
  url=$(cat "$file" | tr -d '[:space:]')

  # Idempotency: skip if already processed
  if source_exists_for_url "$url"; then
    log "SKIP (duplicate): YouTube — file: $file (already in sources)"
    # Still archive the inbox file to avoid re-processing
    mkdir -p "$VAULT_PATH/06-Archive/processed-inbox"
    mv "$file" "$VAULT_PATH/06-Archive/processed-inbox/" 2>/dev/null || true
    return 0
  fi

  run_with_retry "YouTube — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a YouTube video link.
FILE: '$file'
URL: $url

STEP 1 — FETCH TRANSCRIPT
Use full hierarchy: existing → TranscriptAPI → Supadata → local Whisper.

**Step 0 — Check for existing transcript:**
- Search vault for existing notes about this video
- Check ~/.hermes/cache/transcripts/youtube/ for cached transcripts
- If found, use existing content and skip to Step 2

**Primary — TranscriptAPI (\$TRANSCRIPT_API_KEY env var):**
  curl -s 'https://transcriptapi.com/api/v2/youtube/transcript?video_url=$url&format=text&include_timestamp=false&send_metadata=true' \
    -H 'Authorization: Bearer \$TRAN...KEY'
Extract the transcript text and metadata (title, author).

**Fallback 1 — Supadata (\$SUPADATA_API_KEY env var):**
  curl -s 'https://api.supadata.ai/v1/youtube/transcript?url=$url&text=true&lang=en' \
    -H 'x-api-key: \$SUPADATA_API_KEY'
Supadata returns JSON with 'content' (plain text transcript when text=true).
If HTTP 202, poll the returned jobId at /v1/youtube/transcript/{jobId}.

**Fallback 2 — Local Whisper (last resort):**
If both APIs fail, download audio and transcribe locally:
  yt-dlp -x --audio-format mp3 -o "/tmp/%(id)s.%(ext)s" "$url"
  whisper "/tmp/VIDEO_ID.mp3" --model medium --language en --output_format txt
Clean up temporary files after transcription.

If ALL methods fail, create the Source note with the URL and mark
status: needs-transcript.

Convert the transcript into clean, readable markdown paragraphs.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '01-Sources/' with:
  - The YouTube URL, video title, channel name
  - The full transcript as markdown in the 'Original content' section
  - Frontmatter: title, source_url, source_type: youtube, author (channel), tags, status: processed

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft the full Distilled note from the transcript content.
Humanize all prose, then write to '02-Distilled/'.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Extract standalone ideas from the video content.
Draft each, humanize, then write to '03-Atomic/'.

STEP 5 — UPDATE MoCs
Search existing MoCs for relevant topic matches. For each matching or
new MoC:
- Add wikilinks to the new Distilled and Atomic notes
- Include a 1-sentence summary for each new link (not just wikilinks)
- Humanize all MoC prose

STEP 6 — ARCHIVE
Move original inbox file to '06-Archive/processed-inbox/'.
Register the URL in the index: append '\$url\t<source-note-path>' to
'$URL_INDEX'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: Podcasts (existing transcript → AssemblyAI fallback)
# ═══════════════════════════════════════════════════════════
process_podcast() {
  local file="$1"
  local podcast_name=""
  local episode_title=""
  local audio_file=""
  
  # Extract metadata from file
  if [[ "${file##*.}" =~ ^(mp3|m4a|ogg|wav|flac|aac)$ ]]; then
    audio_file="$file"
    # Try to extract podcast name from filename
    basename=$(basename "$file" | sed 's/\.[^.]*$//')
    podcast_name=$(echo "$basename" | cut -d'-' -f1 | tr '_' ' ')
    episode_title=$(echo "$basename" | cut -d'-' -f2- | tr '_' ' ')
  else
    # Parse markdown file for podcast metadata
    podcast_name=$(grep -i "podcast:" "$file" | head -1 | cut -d: -f2- | xargs)
    episode_title=$(grep -i "episode:" "$file" | head -1 | cut -d: -f2- | xargs)
    audio_file=$(grep -i "audio:" "$file" | head -1 | cut -d: -f2- | xargs)
  fi
  
  # Default names if not found
  [[ -z "$podcast_name" ]] && podcast_name="Unknown Podcast"
  [[ -z "$episode_title" ]] && episode_title="Unknown Episode"
  
  local cache_key=$(echo "${podcast_name}_${episode_title}" | md5sum | cut -d' ' -f1)
  
  # Idempotency: skip if already processed
  if source_exists_for_url "podcast://$cache_key"; then
    log "SKIP (duplicate): Podcast — file: $file (already in sources)"
    mkdir -p "$VAULT_PATH/06-Archive/processed-inbox"
    mv "$file" "$VAULT_PATH/06-Archive/processed-inbox/" 2>/dev/null || true
    return 0
  fi

  run_with_retry "Podcast — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a podcast episode.
FILE: '$file'
PODCAST: $podcast_name
EPISODE: $episode_title
AUDIO: $audio_file

STEP 1 — FETCH TRANSCRIPT
Use full hierarchy: existing → AssemblyAI.

**Step 0 — Check for existing transcript:**
- Search vault for existing notes about this podcast/episode
- Check podcast RSS feed show notes for transcript links
- Search podcast website for transcripts
- Check ~/.hermes/cache/transcripts/podcasts/ for cached transcripts
- If found, use existing content and skip to Step 2

**Fallback — AssemblyAI (\$ASSEMBLYAI_API_KEY env var):**
If no existing transcript found, transcribe with AssemblyAI:
  # Upload audio
  UPLOAD_URL=\$(curl -s -X POST 'https://api.assemblyai.com/v2/upload' \\
    -H 'Authorization: \$ASSEMBLYAI_API_KEY' \\
    -H 'Content-Type: application/octet-stream' \\
    --data-binary '@$audio_file' | jq -r '.upload_url')
  
  # Request transcription with speaker labels
  TRANSCRIPT_ID=\$(curl -s -X POST 'https://api.assemblyai.com/v2/transcript' \\
    -H 'Authorization: \$ASSEMBLYAI_API_KEY' \\
    -H 'Content-Type: application/json' \\
    -d '{\"audio_url\": \"'\$UPLOAD_URL'\", \"speaker_labels\": true}' | jq -r '.id')
  
  # Poll for completion
  while true; do
    STATUS=\$(curl -s \"https://api.assemblyai.com/v2/transcript/\$TRANSCRIPT_ID\" \\
      -H 'Authorization: \$ASSEMBLYAI_API_KEY' | jq -r '.status')
    [[ \"\$STATUS\" == \"completed\" ]] && break
    [[ \"\$STATUS\" == \"error\" ]] && exit 1
    sleep 5
  done
  
  # Get final transcript
  curl -s \"https://api.assemblyai.com/v2/transcript/\$TRANSCRIPT_ID\" \\
    -H 'Authorization: \$ASSEMBLYAI_API_KEY' | jq -r '.text'

If ALL methods fail, create the Source note and mark status: needs-transcript.

Convert the transcript into clean, readable markdown paragraphs.
Include speaker labels if available from AssemblyAI.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '01-Sources/' with:
  - Podcast name, episode title, audio source
  - The full transcript as markdown in the 'Original content' section
  - Frontmatter: title, source_url, source_type: podcast, author (podcast name), tags, status: processed

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft the full Distilled note from the transcript content.
Humanize all prose, then write to '02-Distilled/'.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Extract standalone ideas from the podcast content.
Draft each, humanize, then write to '03-Atomic/'.

STEP 5 — UPDATE MoCs
Search existing MoCs for relevant topic matches. For each matching or
new MoC:
- Add wikilinks to the new Distilled and Atomic notes
- Include a 1-sentence summary for each new link (not just wikilinks)
- Humanize all MoC prose

STEP 6 — ARCHIVE
Move original inbox file to '06-Archive/processed-inbox/'.
Register in the index: append 'podcast://$cache_key\t<source-note-path>' to
'$URL_INDEX'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: URLs (Defuddle primary → LiteParse fallback)
# NEW: Checks for existing source before processing
# ═══════════════════════════════════════════════════════════
process_url() {
  local file="$1"
  local url
  url=$(cat "$file" | tr -d '[:space:]')

  # Idempotency: skip if already processed
  if source_exists_for_url "$url"; then
    log "SKIP (duplicate): URL — file: $file (already in sources)"
    mkdir -p "$VAULT_PATH/06-Archive/processed-inbox"
    mv "$file" "$VAULT_PATH/06-Archive/processed-inbox/" 2>/dev/null || true
    return 0
  fi

  run_with_retry "URL — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a URL from the inbox.
FILE: '$file'
URL: $url

STEP 1 — EXTRACT CONTENT
Use Defuddle CLI as the PRIMARY extractor:
  defuddle parse '$url' --md
If Defuddle fails or returns empty/unusable content, FALL BACK to LiteParse:
  Download the page, then: lit parse <downloaded_file> --format text
If both fail, create a minimal Source note with the URL and
mark status: needs-manual-extraction.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '01-Sources/' with extracted markdown content.
Frontmatter: title, source_url, source_type, author, date_captured, tags, status: processed.
IMPORTANT: Wikilinks in YAML frontmatter MUST be quoted
(e.g. source: \"[[note]]\").

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft, humanize, write to '02-Distilled/'.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Draft each, humanize, write to '03-Atomic/'.

STEP 5 — UPDATE MoCs
Search existing MoCs for relevant topics. Add wikilinks with
1-sentence summaries for new notes. Humanize MoC prose.

STEP 6 — ARCHIVE
Move original inbox file to '06-Archive/processed-inbox/'.
Register the URL in the index: append '\$url\t<source-note-path>' to
'$URL_INDEX'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: PDFs and other files (Defuddle primary → LiteParse fallback)
# NEW: Checks for existing source before processing
# ═══════════════════════════════════════════════════════════
process_file() {
  local file="$1"
  local filename
  filename=$(basename "$file")
  local name_no_ext="${filename%.*}"

  run_with_retry "File — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a file from the inbox.
FILE: '$file'
FILENAME: '$filename'

STEP 1 — EXTRACT CONTENT
Try Defuddle first if applicable:
  defuddle parse '$file' --md
If Defuddle can't handle this file type or fails, FALL BACK to LiteParse:
  lit parse '$file' --format text -o '/tmp/${name_no_ext}_extracted.md'
LiteParse handles PDFs, DOCX, PPTX, XLSX, images (with OCR), and more.
Read the extracted text output.

STEP 2 — CREATE SOURCE NOTE
If the file is a PDF: COPY it to '01-Sources/' (keep original for archiving).
For other files: just reference the original path.
Create a Source note in '01-Sources/' with:
  - If PDF: embed it with ![[${filename}]]
  - Include extracted text in 'Original content' section
  - Frontmatter: title, author, source_type, tags, status: processed
  - IMPORTANT: Wikilinks in YAML frontmatter MUST be quoted
    (e.g. source: \"[[note]]\")

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft, humanize, write to '02-Distilled/'.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Draft each, humanize, write to '03-Atomic/'.

STEP 5 — UPDATE MoCs
Search existing MoCs for relevant topics. Add wikilinks with
1-sentence summaries for new notes. Humanize MoC prose.

STEP 6 — ARCHIVE
Move the original inbox file to '06-Archive/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: Clippings (already markdown)
# ═══════════════════════════════════════════════════════════
process_clipping() {
  local file="$1"
  local source_url
  source_url=$(grep -m1 'source_url:' "$file" 2>/dev/null | sed 's/.*source_url: *//; s/^"//; s/"$//' || true)

  # Idempotency for clippings with source_url
  if [ -n "$source_url" ] && source_exists_for_url "$source_url"; then
    log "SKIP (duplicate): Clipping — file: $file (already in sources)"
    mkdir -p "$VAULT_PATH/06-Archive/processed-inbox"
    mv "$file" "$VAULT_PATH/06-Archive/processed-inbox/" 2>/dev/null || true
    return 0
  fi

  run_with_retry "Clipping — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a web clipper save.
FILE: '$file'

The file likely contains markdown captured by Obsidian Web Clipper,
possibly with frontmatter (source_url, title).

STEP 1 — CREATE SOURCE NOTE
Extract the source_url from frontmatter if present.
If it has a source_url and no Source for this URL exists, create a
Source note in '01-Sources/'. If a Source for this URL already exists,
skip Source creation (don't duplicate).

STEP 2 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft, humanize, write to '02-Distilled/'.

STEP 3 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Draft each, humanize, write to '03-Atomic/'.

STEP 4 — UPDATE MoCs
Search existing MoCs for relevant topics. Add wikilinks with
1-sentence summaries for new notes. Humanize MoC prose.

STEP 5 — ARCHIVE
Move the clipping to '06-Archive/processed-inbox/'.
If the clipping had a source_url, register it in '$URL_INDEX'.
"
}

# ═══════════════════════════════════════════════════════════
# MAIN LOOP
# ONLY processes raw/ and clippings/
# NEVER touches quick notes/
# ═══════════════════════════════════════════════════════════
log "Starting inbox processing..."

processed=0
skipped=0
failed=0

# Process everything in raw/
for file in "$VAULT_PATH/00-Inbox/raw"/*; do
  [ -f "$file" ] || continue

  if is_youtube_link "$file"; then
    process_youtube "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
  elif is_podcast_file "$file"; then
    process_podcast "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
  elif is_url_file "$file"; then
    process_url "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
  else
    process_file "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
  fi
done

# Process everything in clippings/
for file in "$VAULT_PATH/00-Inbox/clippings"/*.md; do
  [ -f "$file" ] || continue
  process_clipping "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
done

log "Inbox processing complete. Processed: $processed, Failed: $failed"
log "URL index now has $(wc -l < "$URL_INDEX") entries"
