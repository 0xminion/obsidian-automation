#!/usr/bin/env bash
# ============================================================================
# v2.1.0: Extract Transcript — Universal transcript extraction for YouTube and podcasts
# ============================================================================
# Intelligent fallback chains:
#   YouTube: existing → TranscriptAPI (primary) → Supadata (fallback) → Whisper (last resort)
#   Podcasts: existing → AssemblyAI (fallback)
#
# Usage:
#   ./extract-transcript.sh youtube VIDEO_URL
#   ./extract-transcript.sh podcast AUDIO_FILE [--name "Podcast"] [--episode "Episode"]
#
# Output: Markdown formatted transcript saved to cache and stdout
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/transcribe.sh"

# Configuration
CACHE_DIR="${HOME}/.hermes/cache/transcripts"
mkdir -p "$CACHE_DIR/youtube" "$CACHE_DIR/podcasts"

# ═══════════════════════════════════════════════════════════
# YOUTUBE EXTRACTION
# ═══════════════════════════════════════════════════════════

# Extract YouTube video ID from URL
extract_video_id() {
  local url="$1"
  # POSIX-compatible extraction (no grep -oP or sed \| needed)
  echo "$url" | sed -n 's/.*[?&]v=\([a-zA-Z0-9_-]\{11\}\).*/\1/p; s/.*youtu\.be\/\([a-zA-Z0-9_-]\{11\}\).*/\1/p; s/.*shorts\/\([a-zA-Z0-9_-]\{11\}\).*/\1/p' | head -1
}

# YouTube: Check for existing transcript
youtube_check_existing() {
  local video_id="$1"
  local url="$2"
  
  # Check cache
  if [[ -f "$CACHE_DIR/youtube/${video_id}.json" ]]; then
    local cache_age
    local file_mtime
    file_mtime=$(stat -c %Y "$CACHE_DIR/youtube/${video_id}.json" 2>/dev/null || stat -f %m "$CACHE_DIR/youtube/${video_id}.json" 2>/dev/null || echo 0)
    cache_age=$(($(date +%s) - file_mtime))
    if [[ $cache_age -lt 2592000 ]]; then  # 30 days
      log "Cache HIT for YouTube video: $video_id"
      cat "$CACHE_DIR/youtube/${video_id}.json"
      return 0
    fi
  fi
  
  # Check vault
  local existing=$(find_existing_transcript "$url" "$VAULT_PATH" 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    log "Found existing transcript in vault for: $video_id"
    echo "$existing"
    return 0
  fi
  
  return 1
}

# YouTube: TranscriptAPI (Primary)
youtube_transcriptapi() {
  local url="$1"
  local video_id="$2"
  
  if [[ -z "${TRANSCRIPT_API_KEY:-}" ]]; then
    log "TRANSCRIPT_API_KEY not set, skipping TranscriptAPI"
    return 1
  fi
  
  log "Trying TranscriptAPI for video: $video_id"
  
  local response=$(curl -s -w "\n%{http_code}" \
    "https://transcriptapi.com/api/v2/youtube/transcript?video_url=${url}&format=text&include_timestamp=true&send_metadata=true" \
    -H "Authorization: Bearer $TRANSCRIPT_API_KEY" 2>&1)
  
  local http_code=$(echo "$response" | tail -1)
  local body=$(echo "$response" | head -n -1)
  
  if [[ "$http_code" -eq 200 ]]; then
    log "TranscriptAPI success for: $video_id"
    echo "$body" > "$CACHE_DIR/youtube/${video_id}.json"
    echo "$body"
    return 0
  else
    log "TranscriptAPI failed with HTTP $http_code"
    return 1
  fi
}

# YouTube: Supadata (Fallback)
youtube_supadata() {
  local url="$1"
  local video_id="$2"
  
  if [[ -z "${SUPADATA_API_KEY:-}" ]]; then
    log "SUPADATA_API_KEY not set, skipping Supadata"
    return 1
  fi
  
  log "Trying Supadata for video: $video_id"
  
  local response=$(curl -s -w "\n%{http_code}" \
    -X POST "https://api.supadata.ai/v1/youtube/transcript" \
    -H "Authorization: Bearer $SUPADATA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"video_url\": \"$url\", \"format\": \"text\"}" 2>&1)
  
  local http_code=$(echo "$response" | tail -1)
  local body=$(echo "$response" | head -n -1)
  
  if [[ "$http_code" -eq 200 ]]; then
    log "Supadata success for: $video_id"
    echo "$body" > "$CACHE_DIR/youtube/${video_id}.json"
    echo "$body"
    return 0
  else
    log "Supadata failed with HTTP $http_code"
    return 1
  fi
}

# YouTube: Local Whisper (Last Resort)
youtube_whisper() {
  local url="$1"
  local video_id="$2"
  
  if ! command -v yt-dlp &> /dev/null; then
    log "yt-dlp not installed, cannot use Whisper fallback"
    return 1
  fi
  
  if ! command -v whisper &> /dev/null; then
    log "whisper not installed, cannot use local transcription"
    return 1
  fi
  
  log "Trying local Whisper for video: $video_id"
  
  local temp_audio="/tmp/${video_id}_$(date +%s).mp3"
  
  # Download audio
  log "Downloading audio..."
  if ! yt-dlp -x --audio-format mp3 -o "$temp_audio" "$url" 2>&1 | tee -a "$LOG_FILE"; then
    log "Failed to download audio for: $video_id"
    rm -f "$temp_audio"
    return 1
  fi
  
  # Transcribe
  log "Transcribing with Whisper (this may take a while)..."
  if ! whisper "$temp_audio" \
    --model medium \
    --language en \
    --output_format txt \
    --output_dir "$CACHE_DIR/youtube/" 2>&1 | tee -a "$LOG_FILE"; then
    log "Whisper transcription failed for: $video_id"
    rm -f "$temp_audio"
    return 1
  fi
  
  # Rename output
  mv "$CACHE_DIR/youtube/${video_id}.txt" "$CACHE_DIR/youtube/${video_id}.json" 2>/dev/null || true
  rm -f "$temp_audio"
  
  log "Whisper transcription complete for: $video_id"
  cat "$CACHE_DIR/youtube/${video_id}.json"
  return 0
}

# ═══════════════════════════════════════════════════════════
# PODCAST EXTRACTION
# ═══════════════════════════════════════════════════════════

# Podcast: Check for existing transcript
podcast_check_existing() {
  local url="$1"
  
  # Check vault
  local existing=$(find_existing_transcript "$url" "$VAULT_PATH" 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    log "Found existing transcript in vault for podcast"
    echo "$existing"
    return 0
  fi
  
  # Check cache
  local cache_key=$(echo "$url" | md5sum | cut -d' ' -f1)
  if [[ -f "$CACHE_DIR/podcasts/${cache_key}.json" ]]; then
    local cache_age
    local file_mtime
    file_mtime=$(stat -c %Y "$CACHE_DIR/podcasts/${cache_key}.json" 2>/dev/null || stat -f %m "$CACHE_DIR/podcasts/${cache_key}.json" 2>/dev/null || echo 0)
    cache_age=$(($(date +%s) - file_mtime))
    if [[ $cache_age -lt 2592000 ]]; then  # 30 days
      log "Cache HIT for podcast"
      cat "$CACHE_DIR/podcasts/${cache_key}.json"
      return 0
    fi
  fi
  
  return 1
}

# ═══════════════════════════════════════════════════════════
# MARKDOWN FORMATTING
# ═══════════════════════════════════════════════════════════

format_youtube_markdown() {
  local title="${1:-YouTube Video}"
  local url="$2"
  local method="$3"
  local transcript="$4"
  
  printf '# %s\n**Source:** %s\n**Extracted:** %s\n**Method:** %s\n\n## Transcript\n%s\n\n---\n*Extracted via %s*\n' \
    "$title" "$url" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$method" "$transcript" "$method"
}

format_podcast_markdown() {
  local podcast_name="${1:-Unknown Podcast}"
  local episode_title="${2:-Unknown Episode}"
  local url="$3"
  local method="$4"
  local transcript="$5"
  
  printf '# %s - %s\n**Source:** %s\n**Extracted:** %s\n**Method:** %s\n\n## Transcript\n%s\n\n---\n*Extracted via %s*\n' \
    "$podcast_name" "$episode_title" "$url" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$method" "$transcript" "$method"
}

# ═══════════════════════════════════════════════════════════
# MAIN WORKFLOWS
# ═══════════════════════════════════════════════════════════

extract_youtube() {
  local url="$1"
  local video_id=$(extract_video_id "$url")
  
  if [[ -z "$video_id" ]]; then
    echo "ERROR: Could not extract video ID from URL: $url" >&2
    return 1
  fi
  
  log "Extracting YouTube transcript for video: $video_id"
  
  # Step 0: Check existing
  local existing=$(youtube_check_existing "$video_id" "$url" || true)
  if [[ -n "$existing" ]]; then
    format_youtube_markdown "YouTube Video" "$url" "existing" "$existing"
    return 0
  fi
  
  # Step 1: TranscriptAPI
  local transcript=$(youtube_transcriptapi "$url" "$video_id" || true)
  if [[ -n "$transcript" ]]; then
    format_youtube_markdown "YouTube Video" "$url" "transcriptapi" "$transcript"
    return 0
  fi
  
  # Step 2: Supadata
  transcript=$(youtube_supadata "$url" "$video_id" || true)
  if [[ -n "$transcript" ]]; then
    format_youtube_markdown "YouTube Video" "$url" "supadata" "$transcript"
    return 0
  fi
  
  # Step 3: Whisper
  transcript=$(youtube_whisper "$url" "$video_id" || true)
  if [[ -n "$transcript" ]]; then
    format_youtube_markdown "YouTube Video" "$url" "whisper" "$transcript"
    return 0
  fi
  
  echo "ERROR: All YouTube extraction methods failed for: $url" >&2
  return 1
}

extract_podcast() {
  local url="$1"
  local podcast_name="${2:-Unknown Podcast}"
  local episode_title="${3:-Unknown Episode}"
  
  log "Extracting podcast transcript: $podcast_name - $episode_title"
  
  # Step 0: Check existing
  local existing=$(podcast_check_existing "$url" || true)
  if [[ -n "$existing" ]]; then
    format_podcast_markdown "$podcast_name" "$episode_title" "$url" "existing" "$existing"
    return 0
  fi
  
  # Step 1: Download and transcribe
  local audio_path=$(download_audio "$url" 2>&1 || true)
  if [[ -z "$audio_path" || ! -f "$audio_path" ]]; then
    echo "ERROR: Failed to download podcast audio" >&2
    return 1
  fi
  
  local transcript=$(transcribe_audio "$audio_path" 2>&1 || true)
  rm -f "$audio_path"  # Clean up
  
  if [[ -n "$transcript" ]]; then
    # Cache the transcript
    local cache_key=$(echo "$url" | md5sum | cut -d' ' -f1)
    echo "$transcript" > "$CACHE_DIR/podcasts/${cache_key}.json"
    
    format_podcast_markdown "$podcast_name" "$episode_title" "$url" "assemblyai" "$transcript"
    return 0
  fi
  
  echo "ERROR: Failed to transcribe podcast" >&2
  return 1
}

# ═══════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════

main() {
  if [[ $# -lt 2 ]]; then
    echo "Usage:"
    echo "  $0 youtube VIDEO_URL"
    echo "  $0 podcast AUDIO_FILE [--name \"Podcast Name\"] [--episode \"Episode Title\"]"
    echo ""
    echo "Examples:"
    echo "  $0 youtube https://youtube.com/watch?v=dQw4w9WgXcQ"
    echo "  $0 podcast https://example.com/episode.mp3 --name \"My Podcast\" --episode \"Episode 1\""
    exit 1
  fi
  
  local content_type="$1"
  shift
  
  case "$content_type" in
    youtube)
      extract_youtube "$1"
      ;;
    podcast)
      local url="$1"
      local podcast_name="Unknown Podcast"
      local episode_title="Unknown Episode"
      shift
      
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --name)
            podcast_name="$2"
            shift 2
            ;;
          --episode)
            episode_title="$2"
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done
      
      extract_podcast "$url" "$podcast_name" "$episode_title"
      ;;
    *)
      echo "ERROR: Unknown content type: $content_type" >&2
      echo "Supported: youtube, podcast" >&2
      exit 1
      ;;
  esac
}

main "$@"