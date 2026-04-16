#!/usr/bin/env bash
# ============================================================================
# v2.2: Obsidian Inbox Processor — Karpathy-style LLM Knowledge Base
# ============================================================================
# Watches raw/ and clippings/, processes each file through
# Defuddle (URLs, primary), LiteParse (fallback), or TranscriptAPI (YouTube),
# creates Source note → Entry note → Concept notes → updates MoCs.
#
# Changes from v2.1:
#   - Sources common library (lib/common.sh) — no more duplicated retry/log code
#   - --interactive flag for conversational ingestion
#   - Externalized prompt templates (prompts/*.prompt)
#   - Podcast support via transcribe.sh (AssemblyAI + local whisper fallback)
#   - Source type detection: YouTube, podcast, URL, file, clipping
#   - Typed edges support (edges.tsv)
#   - Git auto-commit after processing
#   - Entry frontmatter includes reviewed/review_notes fields
#
# Usage:
#   bash process-inbox.sh                    # Batch mode (default)
#   bash process-inbox.sh --interactive      # One source at a time with pauses
# ============================================================================

set -uo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/transcribe.sh"
source "$SCRIPT_DIR/../lib/extract.sh"

# ═══════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════
INTERACTIVE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive) INTERACTIVE=true; shift ;;
    -h|--help)
      echo "Usage: process-inbox.sh [--interactive]"
      echo "  --interactive  Pause for human feedback after each source"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ═══════════════════════════════════════════════════════════
# SAFETY & INIT
# ═══════════════════════════════════════════════════════════
acquire_lock "process-inbox" || exit 1
setup_directory_structure
bootstrap_url_index

# ═══════════════════════════════════════════════════════════
# LOAD PROMPT TEMPLATES
# ═══════════════════════════════════════════════════════════
# Shared structure prompts loaded via load_prompt().
# Note: process functions below contain inline prompts (~80% shared Steps 1-9)
# because each source type (YouTube/URL/File/Clipping) needs type-specific
# instructions in Steps 1-2. Externalizing the common Steps 3-9 would add
# complexity without reducing prompt size (agent reads all prompts anyway).
# The prompts/*.prompt files serve as reference templates for agents.
COMMON_INSTRUCTIONS=$(load_prompt "common-instructions")
ENTRY_STRUCTURE=$(load_prompt "entry-structure")
CONCEPT_STRUCTURE=$(load_prompt "concept-structure")
MOC_STRUCTURE=$(load_prompt "moc-structure")

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
  [ -s "$file" ] || return 1  # empty or missing file
  local line_count
  line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
  line_count="${line_count:-0}"
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
# PODCAST DETECTION
# ═══════════════════════════════════════════════════════════
is_podcast_url() {
  local file="$1"
  local url=""
  local content
  content=$(cat "$file" 2>/dev/null | tr -d '[:space:]')

  # Extract URL from file
  if [[ "${file##*.}" == "url" ]]; then
    url=$(extract_url_from_file "$file")
  elif [[ "$content" =~ ^https?:// ]]; then
    url="$content"
  fi

  [ -z "$url" ] && return 1

  # Direct audio file URLs
  [[ "$url" =~ \.(mp3|m4a|wav|ogg|flac|aac)(\?|$) ]] && return 0

  # Podcast platforms
  [[ "$url" =~ (podcasts\.google\.com|podcasts\.apple\.com|open\.spotify\.com/show|open\.spotify\.com/episode|anchor\.fm|buzzsprout\.com|libsyn\.com|podbean\.com|transistor\.fm|simplecast\.com|captivate\.fm|fireside\.fm|podomatic\.com|spreaker\.com|audioboom\.com|soundcloud\.com/.+/sets|soundcloud\.com/[^/]+/[^/]+/?.*$/) ]] && return 0

  # RSS feeds (common podcast feed extensions)
  [[ "$url" =~ \.rss(\?|$)|feed\.xml(\?|$)|/feed/(\?|$)|/rss/(\?|$) ]] && return 0

  return 1
}

# ═══════════════════════════════════════════════════════════
# INTERACTIVE REVIEW
# ═══════════════════════════════════════════════════════════
# Shows a summary and pauses for human feedback
# Returns: 0 = proceed, 1 = skip this source
interactive_review() {
  local source_title="$1"
  local url="${2:-N/A}"

  if ! $INTERACTIVE; then
    return 0  # Batch mode: always proceed
  fi

  echo ""
  echo "═══════════════════════════════════════════════"
  echo "Source ready for review:"
  echo "  Title: $source_title"
  echo "  URL: $url"
  echo ""
  echo "Options: [g]ood (commit & continue) / [s]kip / [q]uit"
  echo -n "> "
  read -r response

  case "$response" in
    g|good|"") return 0 ;;
    s|skip)    return 1 ;;
    q|quit)    echo "Quitting interactive mode."; exit 0 ;;
    *)         return 0 ;;
  esac
}

# ═══════════════════════════════════════════════════════════
# PROCESS: YouTube links
# ═══════════════════════════════════════════════════════════
process_youtube() {
  local file="$1"
  local url
  local ext
  url=$(cat "$file" | tr -d '[:space:]')
  ext="${file##*.}"
  if [[ "$ext" == "url" ]]; then url=$(extract_url_from_file "$file"); fi

  if source_exists_for_url "$url"; then
    skipped=$((skipped + 1))
    log "SKIP (duplicate): YouTube — file: $file"
    mkdir -p "$VAULT_PATH/08-Archive-Raw"
    mv "$file" "$VAULT_PATH/08-Archive-Raw/" 2>/dev/null || true
    return 0
  fi

  # Interactive pre-review
  if ! interactive_review "YouTube: $url" "$url"; then
    skipped=$((skipped + 1))
    log "SKIP (user): YouTube — file: $file"
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
    -H 'Authorization: Bearer \$TRAN...KEY'

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
Include reviewed: null and review_notes: null in frontmatter.

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

STEP 7 — TYPED EDGES
If the content reveals relationships between notes (this extends X,
this contradicts Y, this supports Z), append to '06-Config/edges.tsv':
  source<tab>target<tab>type<tab>description
Types: extends, contradicts, supports, supersedes, tested_by, depends_on, inspired_by

STEP 8 — ARCHIVE
Move original inbox file to '08-Archive-Raw/'.
Register URL in the index: append '\$url\t<source-note-path>' to '$URL_INDEX'.

STEP 9 — LOG ENTRY
Append a structured header to '06-Config/log.md':
  ## [YYYY-MM-DD] ingest | <source-title>
  - Created Source: [[Source Name]]
  - Created Entry: [[Entry Name]]
  - Created/Updated Concepts: [[Concept1]], [[Concept2]]
  - Updated MoCs: [[MoC Name]]
  - Updated wiki-index.md
  - Archived: <filename>
  - Registered URL: <url or \"N/A\">
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: Podcasts (audio download → transcription)
# ═══════════════════════════════════════════════════════════
# Supports: direct MP3 URLs, Apple Podcasts, Spotify, Google Podcasts,
#           Anchor, Buzzsprout, Libsyn, Podbean, SoundCloud, RSS feeds
# Backend: AssemblyAI (primary) or local whisper (fallback)
# Config:  TRANSCRIBE_BACKEND=assemblyai|local
#          ASSEMBLYAI_API_KEY=<key> (for assemblyai backend)
#          LOCAL_WHISPER_CMD=faster-whisper (for local backend)
process_podcast() {
  local file="$1"
  local url=""
  local ext="${file##*.}"

  url=$(cat "$file" | tr -d '[:space:]')
  if [[ "$ext" == "url" ]]; then url=$(extract_url_from_file "$file"); fi

  if source_exists_for_url "$url"; then
    skipped=$((skipped + 1))
    log "SKIP (duplicate): Podcast — file: $file"
    mkdir -p "$VAULT_PATH/08-Archive-Raw"
    mv "$file" "$VAULT_PATH/08-Archive-Raw/" 2>/dev/null || true
    return 0
  fi

  if ! interactive_review "Podcast: $url" "$url"; then
    skipped=$((skipped + 1))
    log "SKIP (user): Podcast — file: $file"
    return 0
  fi

  run_with_retry "Podcast — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a podcast episode into the wiki.
FILE: '$file'
URL: $url
TRANSCRIBE_BACKEND: $TRANSCRIBE_BACKEND

STEP 1 — CHECK FOR EXISTING TRANSCRIPT
Before downloading audio, check if a transcript already exists:
  existing=\\$(source lib/transcribe.sh && find_existing_transcript '$url' '$VAULT_PATH')
If \$existing is non-empty, SKIP Steps 1-2 and use it directly for Steps 3+.
This avoids redundant API calls when re-processing or when a transcript was
provided externally.

STEP 2 — DOWNLOAD AUDIO
Use the download_audio function (from lib/transcribe.sh) to download the audio:
  audio_path=\$(download_audio '$url')
If download fails, try yt-dlp as fallback:
  yt-dlp -x --audio-format mp3 -o '/tmp/podcast_\$(date +%s).mp3' '$url'
If both fail, create a Source note with URL and status: needs-audio.

STEP 3 — TRANSCRIBE AUDIO
Use the transcribe_audio function (from lib/transcribe.sh):
  transcript=\\$(transcribe_audio "$audio_path")
This uses AssemblyAI (primary) or local whisper (fallback) based on config.
If transcription fails, create Source note with URL and status: needs-transcript.

Convert the transcript into clean markdown paragraphs.
Clean up: remove filler words artifacts, fix obvious transcription errors.

STEP 4 — CREATE SOURCE NOTE
Create a Source note in '04-Wiki/sources/' with:
  - Podcast URL, episode title, show name, host(s)
  - Duration if available
  - Full transcript as markdown in 'Original content' section
  - Frontmatter: title, source_url, source_type: podcast, author, date_captured, tags, status: processed

STEP 5 — CREATE ENTRY NOTE
$ENTRY_STRUCTURE
Draft the full Entry note from the transcript.
Humanize all prose, then write to '04-Wiki/entries/'.
IMPORTANT: Use date_entry: (NOT date_distilled:) in frontmatter.
Include reviewed: null and review_notes: null in frontmatter.

STEP 6 — CREATE/UPDATE CONCEPT NOTES
$CONCEPT_STRUCTURE
MANDATORY: Search 04-Wiki/concepts/ BEFORE creating any new concept.
Check if existing concepts cover the same idea. If yes, UPDATE existing
concept (add entry_ref, refresh body if needed). Only create new if truly novel.
Humanize all concept prose before writing.

STEP 7 — UPDATE MoCs
Search 04-Wiki/mocs/ for relevant topic matches. For each matching or new MoC:
- Add wikilinks with 1-sentence summaries for new Entry and Concept notes
- Humanize all MoC prose

STEP 8 — UPDATE WIKI INDEX
Append the new Entry and any new Concepts to '06-Config/wiki-index.md'
with 1-sentence summaries in this format:
  - [[EntryName]]: <1-sentence summary> (entry)
  - [[ConceptName]]: <1-sentence summary> (concept)

STEP 9 — TYPED EDGES
If the content reveals relationships between notes (this extends X,
this contradicts Y, this supports Z), append to '06-Config/edges.tsv':
  source<tab>target<tab>type<tab>description
Types: extends, contradicts, supports, supersedes, tested_by, depends_on, inspired_by

STEP 10 — ARCHIVE
Move original inbox file to '08-Archive-Raw/'.
Register URL in the index: append '\$url\t<source-note-path>' to '$URL_INDEX'.
Clean up downloaded audio file: rm -f \"\$audio_path\"

STEP 11 — LOG ENTRY
Append a structured header to '06-Config/log.md':
  ## [YYYY-MM-DD] ingest | <source-title>
  - Created Source: [[Source Name]]
  - Created Entry: [[Entry Name]]
  - Created/Updated Concepts: [[Concept1]], [[Concept2]]
  - Updated MoCs: [[MoC Name]]
  - Updated wiki-index.md
  - Archived: <filename>
  - Registered URL: <url>
  - Transcription backend: $TRANSCRIBE_BACKEND
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: URLs (Defuddle primary → LiteParse fallback)
# ═══════════════════════════════════════════════════════════
process_url() {
  local file="$1"
  local url
  local ext
  url=$(cat "$file" | tr -d '[:space:]')
  ext="${file##*.}"
  if [[ "$ext" == "url" ]]; then url=$(extract_url_from_file "$file"); fi

  if source_exists_for_url "$url"; then
    skipped=$((skipped + 1))
    log "SKIP (duplicate): URL — file: $file"
    mkdir -p "$VAULT_PATH/08-Archive-Raw"
    mv "$file" "$VAULT_PATH/08-Archive-Raw/" 2>/dev/null || true
    return 0
  fi

  if ! interactive_review "URL: $url" "$url"; then
    skipped=$((skipped + 1))
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

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '04-Wiki/sources/' with extracted markdown.
Frontmatter: title, source_url, source_type, author, date_captured, tags, status: processed
IMPORTANT: Wikilinks in YAML frontmatter MUST be quoted.

STEP 3 — CREATE ENTRY NOTE
$ENTRY_STRUCTURE
Draft the full Entry note. Humanize all prose, write to '04-Wiki/entries/'.
IMPORTANT: Use date_entry: (NOT date_distilled:) in frontmatter.
Include reviewed: null and review_notes: null in frontmatter.

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
Append new Entry and Concepts to '06-Config/wiki-index.md'.

STEP 7 — TYPED EDGES
If relationships exist, append to '06-Config/edges.tsv'.

STEP 8 — ARCHIVE
Move original inbox file to '08-Archive-Raw/'.
Register URL in the index: append '\$url\t<source-note-path>' to '$URL_INDEX'.

STEP 9 — LOG ENTRY
Append a structured header to '06-Config/log.md':
  ## [YYYY-MM-DD] ingest | <source-title>
  - Created Source: [[Source Name]]
  - Created Entry: [[Entry Name]]
  - Created/Updated Concepts: [[Concept1]], [[Concept2]]
  - Updated MoCs: [[MoC Name]]
  - Updated wiki-index.md
  - Archived: <filename>
  - Registered URL: <url or \"N/A\">
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

  local url=""
  url=$(extract_url_from_file "$file" 2>/dev/null || true)
  if [ -n "$url" ] && source_exists_for_url "$url"; then
    skipped=$((skipped + 1))
    log "SKIP (duplicate): File — file: $file"
    mkdir -p "$VAULT_PATH/08-Archive-Raw"
    mv "$file" "$VAULT_PATH/08-Archive-Raw/" 2>/dev/null || true
    return 0
  fi
  # Filename-based dedup for files without URLs
  if [ -f "$VAULT_PATH/04-Wiki/sources/${name_no_ext}.md" ]; then
    skipped=$((skipped + 1))
    log "SKIP (duplicate file): File — file: $file"
    mkdir -p "$VAULT_PATH/08-Archive-Raw"
    mv "$file" "$VAULT_PATH/08-Archive-Raw/" 2>/dev/null || true
    return 0
  fi

  if ! interactive_review "File: $filename" "${url:-N/A}"; then
    skipped=$((skipped + 1))
    return 0
  fi

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
Read the extracted text output.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '04-Wiki/sources/' with extracted markdown.
Frontmatter: title, author, source_type, tags, status: processed

STEP 3 — CREATE ENTRY NOTE
$ENTRY_STRUCTURE
Draft the full Entry note. Humanize all prose, write to '04-Wiki/entries/'.
Include reviewed: null and review_notes: null in frontmatter.

STEP 4 — CREATE/UPDATE CONCEPT NOTES
$CONCEPT_STRUCTURE
Search 04-Wiki/concepts/ BEFORE creating. Update existing or merge. Humanize.

STEP 5 — UPDATE MoCs
Search 04-Wiki/mocs/ for matching topics. Humanize.

STEP 6 — UPDATE WIKI INDEX
Append to '06-Config/wiki-index.md'.

STEP 7 — TYPED EDGES
If relationships exist, append to '06-Config/edges.tsv'.

STEP 8 — ARCHIVE
Move the original file to '08-Archive-Raw/'.

STEP 9 — LOG ENTRY
Append to '06-Config/log.md':
  ## [YYYY-MM-DD] ingest | <source-title>
  - Created Source: [[Source Name]]
  - Created Entry: [[Entry Name]]
  - Created/Updated Concepts: [[Concept1]], [[Concept2]]
  - Updated MoCs: [[MoC Name]]
  - Updated wiki-index.md
  - Archived: <filename>
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
    skipped=$((skipped + 1))
    log "SKIP (duplicate): Clipping — file: $file"
    mkdir -p "$VAULT_PATH/08-Archive-Raw"
    mv "$file" "$VAULT_PATH/08-Archive-Raw/" 2>/dev/null || true
    return 0
  fi

  if ! interactive_review "Clipping: $(basename "$file")" "${source_url:-N/A}"; then
    skipped=$((skipped + 1))
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
If no Source exists for this URL, create one in '04-Wiki/sources/'.

STEP 2 — CREATE ENTRY NOTE
$ENTRY_STRUCTURE
Draft the full Entry note. Humanize all prose, write to '04-Wiki/entries/'.
Include reviewed: null and review_notes: null in frontmatter.

STEP 3 — CREATE/UPDATE CONCEPT NOTES
$CONCEPT_STRUCTURE
Search before creating. Update existing or merge. Humanize.

STEP 4 — UPDATE MoCs
Search 04-Wiki/mocs/ for matching topics. Humanize.

STEP 5 — UPDATE WIKI INDEX
Append to '06-Config/wiki-index.md'.

STEP 6 — TYPED EDGES
If relationships exist, append to '06-Config/edges.tsv'.

STEP 7 — ARCHIVE
Move the clipping to '08-Archive-Raw/'.
Register URL in '$URL_INDEX' if applicable.

STEP 8 — LOG ENTRY
Append to '06-Config/log.md':
  ## [YYYY-MM-DD] ingest | <source-title>
  - Created Source: [[Source Name]]
  - Created Entry: [[Entry Name]]
  - Created/Updated Concepts: [[Concept1]], [[Concept2]]
  - Updated MoCs: [[MoC Name]]
  - Updated wiki-index.md
  - Archived: <filename>
"
}

# ═══════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════
processed=0
skipped=0
failed=0

log "=== Starting inbox processing (v2.2, interactive=$INTERACTIVE) ==="

# Process everything in 01-Raw/
if [ -d "$VAULT_PATH/01-Raw" ]; then
  for file in "$VAULT_PATH/01-Raw"/*; do
    [ -f "$file" ] || continue

    if is_youtube_link "$file"; then
      process_youtube "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
    elif is_podcast_url "$file"; then
      process_podcast "$file" && processed=$((processed + 1)) || failed=$((failed + 1))
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

log "Inbox processing complete (v2.2). Processed: $processed, Skipped: $skipped, Failed: $failed"
log "URL index now has $(wc -l < "$URL_INDEX") entries"

# ═══════════════════════════════════════════════════════════
# POST-INGEST: Update config files
# ═══════════════════════════════════════════════════════════
if [ "$processed" -gt 0 ]; then
  log "Updating dashboard, tag-registry, and wiki-index..."
  
  # Update dashboard
  bash "$SCRIPT_DIR/vault-stats.sh" 2>/dev/null && log "Dashboard updated" || log "Dashboard update failed"
  
  # Update tag registry
  bash "$SCRIPT_DIR/update-tag-registry.sh" 2>/dev/null && log "Tag registry updated" || log "Tag registry update failed"
  
  # Full wiki-index rebuild (only if >5 notes processed to avoid overhead)
  if [ "$processed" -ge 5 ]; then
    bash "$SCRIPT_DIR/reindex.sh" 2>/dev/null && log "Wiki index rebuilt" || log "Wiki index rebuild failed"
  fi
fi

# Git auto-commit
auto_commit "ingest" "Processed $processed sources (skipped $skipped, failed $failed)"

echo "Done. Processed: $processed, Skipped: $skipped, Failed: $failed"
