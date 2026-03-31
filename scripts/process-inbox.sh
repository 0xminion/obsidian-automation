#!/usr/bin/env bash
# ============================================================================
# Obsidian Inbox Processor — Hermes Agent + headless file operations
# Watches 00 Inbox/raw/ and 00 Inbox/clippings/, processes each file through
# Defuddle (URLs), LiteParse (PDFs), or direct handling (YouTube/misc),
# creates Source → Distilled → Atomic notes, humanizes AI prose, updates MoCs.
#
# NOTE: obsidian CLI (obsidian create/append/search) requires the Obsidian app
# running locally. This script uses direct file operations instead (cp, mv, cat,
# mkdir, find) which work in any headless context.
# ============================================================================

set -euo pipefail

# ═══════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════
VAULT_PATH="${VAULT_PATH:-$HOME/cvjji9}"
LOG_FILE="$VAULT_PATH/Logs/processing.log"
LOCK_FILE="/tmp/obsidian-inbox-processor.lock"
AGENT_CMD="${AGENT_CMD:-hermes run --prompt}"
SKILLS="obsidian-markdown, obsidian-cli, defuddle, humanizer, transcriptapi"

# Load TranscriptAPI key from openclaw config (set by clawhub install)
TRANSCRIPT_API_KEY="${TRANSCRIPT_API_KEY:-$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$HOME/.openclaw/openclaw.json','utf8')).skills.entries.transcriptapi.apiKey)}catch(e){console.log('')}" 2>/dev/null)}"

# ═══════════════════════════════════════════════════════════
# Safety: prevent overlapping runs
# ═══════════════════════════════════════════════════════════
if [ -f "$LOCK_FILE" ]; then
  echo "$(date): Another instance is running. Exiting." >> "$LOG_FILE"
  exit 0
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

log() { echo "$(date): $1" >> "$LOG_FILE"; }
log "Starting inbox processing..."

# ═══════════════════════════════════════════════════════════
# File type detection helpers
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
  local ext="${1##*.}"
  [[ "${ext,,}" == "pdf" ]]
}

is_youtube_link() {
  local content
  content=$(cat "$1" | tr -d '[:space:]')
  [[ "$content" =~ (youtube\.com|youtu\.be) ]]
}

# ═══════════════════════════════════════════════════════════
# SHARED PROMPT INSTRUCTIONS
# ═══════════════════════════════════════════════════════════
COMMON_INSTRUCTIONS="
VAULT LOCATION: $VAULT_PATH
AGENT SKILLS AVAILABLE: $SKILLS

CRITICAL RULES:
1. NEVER touch anything in '00 Inbox/quick notes/'. That folder is off-limits.
2. ALL AI-generated prose written to '02-Distilled/', '03-Atomic/', or '04-MoCs/'
   MUST be run through the Humanizer skill before writing to disk.
   Draft the content, then humanize it, then write the final file.
3. Use [[wikilinks]] for all internal vault links. Never use markdown links.
4. Use Obsidian-flavored markdown (callouts, frontmatter properties, tags).
5. File operations: use terminal with 'cp', 'mv', 'cat', 'mkdir', 'find', etc.
   Create notes by writing .md files directly to the vault directory.
   Search notes using 'grep -r' or 'find . -name \"*.md\" | xargs grep'.
   No obsidian CLI commands available — use direct file I/O instead.
6. Source notes go in '01-Sources/'. Processed originals go in '06-Archive-processed/processed-inbox/'.
"

# ═══════════════════════════════════════════════════════════
# DISTILLED NOTE STRUCTURE (strict)
# ═══════════════════════════════════════════════════════════
DISTILLED_STRUCTURE="
DISTILLED NOTE STRUCTURE — follow this EXACTLY for every note in '02-Distilled/':

Frontmatter required:
  - title, source (wikilink), date_distilled, status: review
  - tags: minimum 5, maximum 10 topic-specific tags (not counting 'distilled')

Body sections IN THIS ORDER:

## TL;DR
3-5 sentence summary. Plain language, no fluff.

## Findings

### Core findings
The main findings. As many bullet points as the content warrants — extract EVERYTHING
significant. No artificial limits.

### Other takeaways
Other important findings. No artificial limits.

## Diagrams
If content involves processes, relationships, hierarchies, comparisons:
include a Mermaid diagram. If no diagram would genuinely help, write 'N/A.'

## Open questions
Questions, gaps, or issues raised by the content worth thinking about further.

## Linked concepts
Wikilinks to related Atomic notes, Distilled notes, and MoCs.
"

# ═══════════════════════════════════════════════════════════
# ATOMIC NOTE RULES
# ═══════════════════════════════════════════════════════════
ATOMIC_RULES="
ATOMIC NOTE RULES for '03-Atomic/':
- One clear, standalone idea per note.
- Title = the idea expressed as a concise phrase.
- Body = 2-5 sentences. No padding.
- Frontmatter tags: minimum 2, maximum 5 topic-specific tags (not counting 'atomic').
- Always include a wikilink back to the Source and Distilled notes.
- Search vault for related existing notes and add wikilinks.
- ALL prose must be humanized before writing.
"

# ═══════════════════════════════════════════════════════════
# Process URL-based files in raw/
# Uses: Defuddle (web content extraction)
# ═══════════════════════════════════════════════════════════
process_url() {
  local file="$1"
  log "Processing URL: $file"

  local url
  url=$(cat "$file" | tr -d '[:space:]')

  cd "$VAULT_PATH"
  $AGENT_CMD "
$COMMON_INSTRUCTIONS

TASK: Process a URL from the inbox.
FILE: '$file'
URL: '$url'

STEP 1 — EXTRACT CONTENT
Use Defuddle CLI to extract clean markdown:
  defuddle parse '$url' --md
Defuddle strips ads, navigation, and clutter, returning only the main content.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '01-Sources/' — write a .md file directly.
Frontmatter: title, source_url, source_type (article/blog/documentation/etc),
  author (extract from content), date_captured (today), tags, status: processed
Include the full extracted content in an 'Original content' section.

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft the full Distilled note, then HUMANIZE all prose sections before writing.
Write the humanized version to '02-Distilled/' as a .md file.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
For each distinct, standalone idea worth preserving, create an Atomic note.
Draft each one, humanize, then write to '03-Atomic/' as .md files.

STEP 5 — UPDATE MoCs
Search existing MoCs in '04-MoCs/' using grep/find.
If a related MoC exists: append wikilinks to the new notes in the relevant sections.
If no matching MoC exists and the topic is substantial enough to warrant one:
create a new MoC (humanize the prose before writing) as a .md file in '04-MoCs/'.

STEP 6 — ARCHIVE
Move the original inbox file to '06-Archive-processed/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# Process PDF files in raw/
# Uses: LiteParse (PDF text extraction)
# ═══════════════════════════════════════════════════════════
process_pdf() {
  local file="$1"
  local filename
  filename=$(basename "$file" .pdf)
  log "Processing PDF: $file"

  cd "$VAULT_PATH"
  $AGENT_CMD "
$COMMON_INSTRUCTIONS

TASK: Process a PDF from the inbox.
FILE: '$file'
FILENAME: '$filename'

STEP 1 — EXTRACT TEXT
Use LiteParse to parse the PDF to text:
  lit parse '$file' --format text -o /tmp/${filename}_extracted.md
Read the extracted text output.

STEP 2 — CREATE SOURCE NOTE
Copy the PDF file to '01-Sources/' (keep it for embedding).
Create a Source note in '01-Sources/' with:
  - Embed the PDF: ![[\${filename}.pdf]]
  - Include extracted text in an 'Original content' section
  - Frontmatter: title, author, source_type: pdf, tags, status: processed
  Write as a .md file directly to '01-Sources/'.

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft the full Distilled note, then HUMANIZE all prose sections before writing.
Write the humanized version to '02-Distilled/' as a .md file.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Extract as many atomic ideas as the content warrants.
Draft each, humanize, then write to '03-Atomic/' as .md files.

STEP 5 — UPDATE MoCs
Search for and update relevant MoCs, or create new ones if warranted.
Humanize all MoC prose before writing.

STEP 6 — ARCHIVE
Move the original inbox entry (not the PDF, now in 01-Sources/) to '06-Archive-processed/processed-inbox/'.
"
}
# ═══════════════════════════════════════════════════════════
# Process YouTube links in raw/
# Uses: TranscriptAPI via curl (youtube-full skill)
# ═══════════════════════════════════════════════════════════
process_youtube() {
  local file="$1"
  log "Processing YouTube link: $file"

  local url
  url=$(cat "$file" | tr -d '[:space:]')

  # Extract video ID for the API call
  local video_id
  video_id=$(echo "$url" | sed -E 's/.*(v=|youtu\.be\/)([a-zA-Z0-9_-]{11}).*/\2/')

  if [ -z "$video_id" ]; then
    log "ERROR: Could not extract video ID from YouTube URL: $url"
    mkdir -p "$VAULT_PATH/00-Inbox/failed"
    mv "$file" "$VAULT_PATH/00-Inbox/failed/"
    return 1
  fi

  cd "$VAULT_PATH"
  $AGENT_CMD "
$COMMON_INSTRUCTIONS

TASK: Process a YouTube video from the inbox.
FILE: '$file'
URL: '$url'
VIDEO_ID: '$video_id'

STEP 1 — FETCH TRANSCRIPT
Use TranscriptAPI to get the full transcript.
TRANSCRIPT_API_KEY is set in the environment (loaded from ~/.openclaw/openclaw.json).
Make this exact call:
  curl -s 'https://transcriptapi.com/api/v2/youtube/transcript?video_url=$url&format=text&include_timestamp=true&send_metadata=true' \\
    -H "Authorization: Bearer $TRANSCRIPT_API_KEY"
Extract: video title, channel name, and the full transcript text.
If the API returns a 402 (no credits) or 404 (no captions), note this in the Source
and create Distilled/Atomic notes from whatever metadata is available.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '01-Sources/' as a .md file with:
  - Frontmatter: title (video title), source_url: '$url', source_type: youtube,
    author (channel name), date_captured (today), tags, status: processed
  - Include the full transcript in an 'Original content' section
  Write the file directly using terminal/file tools.

STEP 3 — CREATE DISTILLED NOTE
\$DISTILLED_STRUCTURE
Draft the full Distilled note, then HUMANIZE all prose before writing.
Write to '02-Distilled/' as a .md file.

STEP 4 — CREATE ATOMIC NOTES
\$ATOMIC_RULES
Extract as many standalone atomic ideas as the content warrants.
Draft each, humanize, then write to '03-Atomic/' as .md files.

STEP 5 — UPDATE MoCs
Search for and update relevant MoCs in '04-MoCs/'. Humanize any new MoC prose.

STEP 6 — ARCHIVE
Move the original inbox file to '06-Archive-processed/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# Process other files in raw/
# ═══════════════════════════════════════════════════════════
process_other_raw() {
  local file="$1"
  log "Processing other raw file: $file"

  cd "$VAULT_PATH"
  $AGENT_CMD "
$COMMON_INSTRUCTIONS

TASK: Process a raw inbox item.
FILE: '$file'

Read the file and determine what it is.

For markdown/text content: create a Source note, then follow the standard
Distilled → Atomic → MoC pipeline. Write all files directly as .md.

$DISTILLED_STRUCTURE
$ATOMIC_RULES

HUMANIZE all prose in '02-Distilled/', '03-Atomic/', and '04-MoCs/' before writing.
Move the processed file to '06-Archive-processed/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# Process clippings (web clipper saves)
# ═══════════════════════════════════════════════════════════
process_clipping() {
  local file="$1"
  log "Processing clipping: $file"

  cd "$VAULT_PATH"
  $AGENT_CMD "
$COMMON_INSTRUCTIONS

TASK: Process a web clipper save.
FILE: '$file'

Read the file. It likely contains markdown content captured by Obsidian Web Clipper,
possibly with frontmatter (source_url, title).

STEP 1 — CREATE/UPDATE SOURCE NOTE
If the clipping has a source_url, create a Source note in '01-Sources/'
as a .md file with the clipped content as the original.

STEP 2 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft, humanize, then write to '02-Distilled/' as a .md file.

STEP 3 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Draft each, humanize, then write to '03-Atomic/' as .md files.

STEP 4 — UPDATE MoCs
Search and update relevant MoCs. Humanize any new MoC prose.

STEP 5 — ARCHIVE
Move the clipping to '06-Archive-processed/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# MAIN LOOP — Process raw/ and clippings/ only
# NEVER TOUCH quick notes/
# ═══════════════════════════════════════════════════════════
for file in "$VAULT_PATH/00-Inbox/raw"/*; do
  [ -f "$file" ] || continue

  if is_pdf_file "$file"; then
    process_pdf "$file"
  elif is_youtube_link "$file"; then
    process_youtube "$file"
  elif is_url_file "$file"; then
    process_url "$file"
  else
    process_other_raw "$file"
  fi
done

for file in "$VAULT_PATH/00-Inbox/clippings"/*.md; do
  [ -f "$file" ] || continue
  process_clipping "$file"
done

log "Inbox processing complete."
