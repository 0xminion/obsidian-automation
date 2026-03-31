#!/usr/bin/env bash
# ============================================================================
# Obsidian Inbox Processor — Agent-agnostic + headless file operations
# Watches 00-Inbox/raw/ and 00-Inbox/clippings/, processes each file through
# Defuddle (URLs, primary), LiteParse (fallback), or TranscriptAPI (YouTube),
# creates Source → Distilled → Atomic notes, humanizes AI prose, updates MoCs.
#
# Supports: Claude Code, Hermes Agent, Codex CLI, or any agentskills.io agent.
# Includes retry logic with exponential backoff.
# ============================================================================

set -euo pipefail

# ═══════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════
VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
mkdir -p "$VAULT_PATH/Meta/Scripts"
LOG_FILE="$VAULT_PATH/Meta/Scripts/processing.log"
LOCK_FILE="/tmp/obsidian-inbox-processor-$(echo "$VAULT_PATH" | md5sum | cut -c1-8).lock"
MAX_RETRIES=3

# Agent command — change for your agent
# Claude Code:   AGENT_CMD="claude -p"
# Hermes Agent:  AGENT_CMD="hermes run --prompt"
# Codex CLI:     AGENT_CMD="codex exec"
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
# RETRY LOGIC — exponential backoff, max 3 attempts
# On failure, instructs the agent to try alternative approaches
# ═══════════════════════════════════════════════════════════
run_with_retry() {
  local description="$1"
  local prompt="$2"
  local attempt=1
  local delay=5  # initial delay in seconds

  while [ $attempt -le $MAX_RETRIES ]; do
    log "Attempt $attempt/$MAX_RETRIES: $description"

    if cd "$VAULT_PATH" && $AGENT_CMD "$prompt" 2>> "$LOG_FILE"; then
      log "SUCCESS: $description"
      return 0
    fi

    local exit_code=$?
    log "FAILED (exit $exit_code): $description — attempt $attempt/$MAX_RETRIES"

    if [ $attempt -lt $MAX_RETRIES ]; then
      log "Waiting ${delay}s before retry (exponential backoff)..."
      sleep $delay
      delay=$((delay * 2))

      # Augment the prompt with retry instructions
      prompt="$prompt

RETRY CONTEXT: This is attempt $((attempt + 1)) of $MAX_RETRIES.
The previous attempt failed. Try alternative approaches:
- If a URL failed with Defuddle, fall back to LiteParse or direct fetch.
- If PDF parsing failed, try with --no-ocr flag or different page ranges.
- If the TranscriptAPI call failed, try with a bare video ID instead of full URL.
- If a file operation failed, check if the target directory exists and create it.
- If an API call was rate-limited, use a simpler/shorter prompt.
- If note creation failed, verify the file path and try writing to a temp location first.
Be resourceful. Find a way to complete the task."
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

# ═══════════════════════════════════════════════════════════
# SHARED PROMPT INSTRUCTIONS
# ═══════════════════════════════════════════════════════════
COMMON_INSTRUCTIONS="
VAULT LOCATION: $VAULT_PATH
AGENT SKILLS AVAILABLE: obsidian-markdown, obsidian-cli, defuddle, humanizer,
  youtube-full (TranscriptAPI), liteparse

CRITICAL RULES:
1. NEVER touch anything in '00-Inbox/quick notes/'. Off-limits.
2. ALL AI-generated prose for 02-Distilled/, 03-Atomic/, or 04-MoCs/
   MUST be run through the Humanizer skill before writing to disk.
   Draft the content → humanize it → write the final file.
3. Use [[wikilinks]] for all internal vault links.
4. Use Obsidian-flavored markdown (callouts, frontmatter, tags).
5. Use obsidian CLI where helpful:
   obsidian create, obsidian search, obsidian append, obsidian property:set
6. Source notes go in '01-Sources/'. Processed originals go in '06-Archive/processed-inbox/'.

PARSER ROUTING:
- Primary: Use Defuddle for any URLs and applicable file-to-markdown conversions.
- Fallback: If Defuddle fails or can't handle the format, fall back to LiteParse:
    lit parse <file> --format text
- YouTube links: Use TranscriptAPI (youtube-full skill) exclusively.
  API call: curl -s 'https://transcriptapi.com/api/v2/youtube/transcript?video_url=VIDEO_URL&format=text&include_timestamp=true&send_metadata=true'
    -H 'Authorization: Bearer \$TRANSCRIPT_API_KEY'
  Then convert the transcript to clean markdown.

TAG CONSOLIDATION:
Before creating new tags, ALWAYS search existing tags in the vault first:
  obsidian tags sort=count counts
Reuse existing tags wherever possible. Only create a new tag if no existing
tag covers the concept. This prevents tag sprawl and keeps the taxonomy clean.

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
# PROCESS: YouTube links (TranscriptAPI → markdown)
# ═══════════════════════════════════════════════════════════
process_youtube() {
  local file="$1"
  local url
  url=$(cat "$file" | tr -d '[:space:]')

  run_with_retry "YouTube — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a YouTube video link.
FILE: '$file'
URL: $url

STEP 1 — FETCH TRANSCRIPT
Use the TranscriptAPI skill (youtube-full) to get the transcript:
  curl -s 'https://transcriptapi.com/api/v2/youtube/transcript?video_url=$url&format=text&include_timestamp=true&send_metadata=true' \\
    -H 'Authorization: Bearer \$TRANSCRIPT_API_KEY'
Extract the transcript text and metadata (title, author).
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
Search existing MoCs: obsidian search query=\"<topic>\"
Update relevant MoCs or create new ones if warranted. Humanize MoC prose.

STEP 6 — ARCHIVE
Move original inbox file to '06-Archive/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: URLs (Defuddle primary → LiteParse fallback)
# ═══════════════════════════════════════════════════════════
process_url() {
  local file="$1"

  run_with_retry "URL — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a URL from the inbox.
FILE: '$file'

STEP 1 — EXTRACT CONTENT
Read the file to get the URL. Use Defuddle CLI as the PRIMARY extractor:
  defuddle parse <the_url> --md
If Defuddle fails or returns empty/unusable content, FALL BACK to LiteParse:
  Download the page, then: lit parse <downloaded_file> --format text
If both fail, create a minimal Source note with the URL and mark status: needs-manual-extraction.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '01-Sources/' with extracted markdown content.
Frontmatter: title, source_url, source_type, author, date_captured, tags, status: processed.
IMPORTANT: Wikilinks in YAML frontmatter MUST be quoted (e.g. source: \"[[note]]\").

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft, humanize, write to '02-Distilled/'.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Draft each, humanize, write to '03-Atomic/'.

STEP 5 — UPDATE MoCs
Search and update or create relevant MoCs. Humanize MoC prose.

STEP 6 — ARCHIVE
Move original inbox file to '06-Archive/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: PDFs and other files (Defuddle primary → LiteParse fallback)
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
  - IMPORTANT: Wikilinks in YAML frontmatter MUST be quoted (e.g. source: \"[[note]]\")

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft, humanize, write to '02-Distilled/'.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Draft each, humanize, write to '03-Atomic/'.

STEP 5 — UPDATE MoCs
Search and update or create relevant MoCs. Humanize MoC prose.

STEP 6 — ARCHIVE
Move the original inbox file to '06-Archive/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: Clippings (already markdown)
# ═══════════════════════════════════════════════════════════
process_clipping() {
  local file="$1"

  run_with_retry "Clipping — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a web clipper save.
FILE: '$file'

The file likely contains markdown captured by Obsidian Web Clipper,
possibly with frontmatter (source_url, title).

STEP 1 — CREATE SOURCE NOTE
If it has a source_url, create a Source note in '01-Sources/'.
If a Source for this URL already exists, update it.

STEP 2 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft, humanize, write to '02-Distilled/'.

STEP 3 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Draft each, humanize, write to '03-Atomic/'.

STEP 4 — UPDATE MoCs
Search and update or create relevant MoCs. Humanize MoC prose.

STEP 5 — ARCHIVE
Move the clipping to '06-Archive/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# MAIN LOOP
# ONLY processes raw/ and clippings/
# NEVER touches quick notes/
# ═══════════════════════════════════════════════════════════
log "Starting inbox processing..."

# Process everything in raw/
for file in "$VAULT_PATH/00-Inbox/raw"/*; do
  [ -f "$file" ] || continue

  if is_youtube_link "$file"; then
    process_youtube "$file"
  elif is_url_file "$file"; then
    process_url "$file"
  else
    process_file "$file"
  fi
done

# Process everything in clippings/
for file in "$VAULT_PATH/00-Inbox/clippings"/*.md; do
  [ -f "$file" ] || continue
  process_clipping "$file"
done

log "Inbox processing complete."
