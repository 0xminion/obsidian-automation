#!/usr/bin/env bash
# ============================================================================
# Transcription Abstraction Layer
# ============================================================================
# Provides audio transcription via pluggable backends.
# Primary: AssemblyAI (free tier: 100hrs/month)
# Fallback: local whisper (user-configured, not auto-installed)
#
# Source this from any script: source "lib/transcribe.sh"
# Requires: common.sh to be sourced first (for log())
# ============================================================================

set -uo pipefail

# ═══════════════════════════════════════════════════════════
# JSON PARSING HELPER
# ═══════════════════════════════════════════════════════════
# Safely extract a field from JSON. Handles escaped quotes, unicode, etc.
# Usage: value=$(json_field "$json_string" "field_name")
json_field() {
  echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get(sys.argv[1],''))" "$2" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════
# Transcription backend: "assemblyai" or "local"
TRANSCRIBE_BACKEND="${TRANSCRIBE_BACKEND:-assemblyai}"

# AssemblyAI
ASSEMBLYAI_API_KEY="${ASSEMBLYAI_API_KEY:-}"
ASSEMBLYAI_API_URL="${ASSEMBLYAI_API_URL:-https://api.assemblyai.com}"
ASSEMBLYAI_MODEL="${ASSEMBLYAI_MODEL:-universal-2}"

# Local whisper (not installed by default — user configures)
LOCAL_WHISPER_CMD="${LOCAL_WHISPER_CMD:-}"          # e.g., "faster-whisper" or "whisper"
LOCAL_WHISPER_MODEL="${LOCAL_WHISPER_MODEL:-large-v3}"
LOCAL_WHISPER_LANGUAGE="${LOCAL_WHISPER_LANGUAGE:-en}"

# Temp directory for audio downloads
TRANSCRIBE_TMP_DIR="${TRANSCRIBE_TMP_DIR:-/tmp/obsidian-transcribe}"

# Transcript cache: reuse previous transcriptions
TRANSCRIPT_CACHE_DIR="${TRANSCRIPT_CACHE_DIR:-$HOME/.cache/obsidian-transcripts}"

# ═══════════════════════════════════════════════════════════
# TRANSCRIPT CACHE
# ═══════════════════════════════════════════════════════════
# Avoid re-transcribing audio that was already processed.
# Cache key: SHA256 of audio file.

# Check if a cached transcript exists for an audio file.
# Usage: cached=$(find_cached_transcript "/path/to/audio.mp3")
# Returns: transcript text on stdout, or empty string if not cached
find_cached_transcript() {
  local audio_file="$1"
  if [ ! -f "$audio_file" ]; then return 1; fi

  local hash
  hash=$(sha256sum "$audio_file" | cut -d' ' -f1)
  local cache_file="$TRANSCRIPT_CACHE_DIR/${hash}.txt"

  if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
    log "Transcript cache HIT: $hash ($(basename "$audio_file"))"
    cat "$cache_file"
    return 0
  fi

  return 1
}

# Save a transcript to the cache.
# Usage: save_cached_transcript "/path/to/audio.mp3" "$transcript"
save_cached_transcript() {
  local audio_file="$1"
  local transcript="$2"

  local hash
  hash=$(sha256sum "$audio_file" | cut -d' ' -f1)
  mkdir -p "$TRANSCRIPT_CACHE_DIR"
  echo "$transcript" > "$TRANSCRIPT_CACHE_DIR/${hash}.txt"
  log "Transcript cached: $hash ($(basename "$audio_file"))"
}

# Check if existing transcript text is available (file or Source note).
# Usage: existing=$(find_existing_transcript "$url" "$vault_path")
# Checks: 1) Source note with transcript, 2) cached .txt by URL hash
find_existing_transcript() {
  local url="$1"
  local vault_path="${2:-$VAULT_PATH}"

  # Check Source notes for existing transcript
  local url_hash
  url_hash=$(echo -n "$url" | sha256sum | cut -d' ' -f1)
  local cache_file="$TRANSCRIPT_CACHE_DIR/url_${url_hash}.txt"

  if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
    log "Transcript cache HIT for URL: $url"
    cat "$cache_file"
    return 0
  fi

  # Check if a Source note already has transcript content
  if [ -d "$vault_path/04-Wiki/sources" ]; then
    local existing
    existing=$(grep -rl "$url" "$vault_path/04-Wiki/sources/" 2>/dev/null | head -1)
    if [ -n "$existing" ]; then
      # Extract transcript from "## Original Content" or "## Transcript" section
      local transcript
      transcript=$(awk '/^## (Original Content|Transcript)/{found=1; next} /^## /{if(found) exit} found{print}' "$existing" 2>/dev/null)
      if [ -n "$transcript" ] && [ "${#transcript}" -gt 100 ]; then
        log "Found existing transcript in Source note: $(basename "$existing")"
        echo "$transcript"
        return 0
      fi
    fi
  fi

  return 1
}

# Save URL-based transcript to cache.
# Usage: save_url_transcript "$url" "$transcript"
save_url_transcript() {
  local url="$1"
  local transcript="$2"

  local url_hash
  url_hash=$(echo -n "$url" | sha256sum | cut -d' ' -f1)
  mkdir -p "$TRANSCRIPT_CACHE_DIR"
  echo "$transcript" > "$TRANSCRIPT_CACHE_DIR/url_${url_hash}.txt"
  log "URL transcript cached: $url"
}

# ═══════════════════════════════════════════════════════════
# ASSEMBLYAI TRANSCRIPTION
# ═══════════════════════════════════════════════════════════
# Flow: upload audio → submit transcript → poll → get text
#
# Usage: transcript=$(transcribe_assemblyai "/path/to/audio.mp3")
# Returns: transcript text on stdout, or exits 1 on failure
transcribe_assemblyai() {
  local audio_file="$1"

  if [ -z "$ASSEMBLYAI_API_KEY" ]; then
    echo "ERROR: ASSEMBLYAI_API_KEY not set. Get free key at https://www.assemblyai.com/" >&2
    return 1
  fi

  if [ ! -f "$audio_file" ]; then
    echo "ERROR: Audio file not found: $audio_file" >&2
    return 1
  fi

  log "AssemblyAI: Uploading $(basename "$audio_file") ($(du -h "$audio_file" | cut -f1))"

  # Step 1: Upload audio file
  local upload_response
  upload_response=$(curl -s -X POST "$ASSEMBLYAI_API_URL/v2/upload" \
    -H "Authorization: $ASSEMBLYAI_API_KEY" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$audio_file" \
    --max-time 300 2>>"$LOG_FILE")

  local upload_url
  upload_url=$(json_field "$upload_response" "upload_url")

  if [ -z "$upload_url" ]; then
    echo "ERROR: AssemblyAI upload failed" >&2
    log "AssemblyAI: Upload failed for $audio_file"
    return 1
  fi

  log "AssemblyAI: Uploaded. Submitting transcript request..."

  # Step 2: Submit transcript request
  local transcript_id
  local submit_response
  submit_response=$(curl -s -X POST "$ASSEMBLYAI_API_URL/v2/transcript" \
    -H "Authorization: $ASSEMBLYAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"audio_url\": \"$upload_url\", \"speech_models\": [\"$ASSEMBLYAI_MODEL\"], \"punctuate\": true, \"format_text\": true}" \
    --max-time 30 2>>"$LOG_FILE")

  transcript_id=$(json_field "$submit_response" "id")

  if [ -z "$transcript_id" ]; then
    echo "ERROR: AssemblyAI transcript submission failed" >&2
    log "AssemblyAI: Submit failed. Response: $submit_response"
    return 1
  fi

  log "AssemblyAI: Transcript job submitted (ID: $transcript_id). Polling..."

  # Step 3: Poll until complete
  local max_polls=120  # 10 minutes max (5s intervals)
  local poll_count=0
  local status=""

  while [ $poll_count -lt $max_polls ]; do
    local poll_response
    poll_response=$(curl -s "$ASSEMBLYAI_API_URL/v2/transcript/$transcript_id" \
      -H "Authorization: $ASSEMBLYAI_API_KEY" \
      --max-time 10 2>>"$LOG_FILE")

    status=$(json_field "$poll_response" "status")

    case "$status" in
      completed)
        # Extract transcript text via python3 (handles escaped quotes, unicode)
        local text
        text=$(json_field "$poll_response" "text")

        if [ -z "$text" ]; then
          echo "ERROR: AssemblyAI returned empty transcript" >&2
          log "AssemblyAI: Empty transcript for $transcript_id"
          return 1
        fi

        log "AssemblyAI: Transcription complete (${#text} chars)"
        echo "$text"
        return 0
        ;;
      error)
        local error_msg
        error_msg=$(json_field "$poll_response" "error")
        echo "ERROR: AssemblyAI transcription failed: $error_msg" >&2
        log "AssemblyAI: Error for $transcript_id: $error_msg"
        return 1
        ;;
      queued|processing)
        sleep 5
        poll_count=$((poll_count + 1))
        ;;
      *)
        sleep 5
        poll_count=$((poll_count + 1))
        ;;
    esac
  done

  echo "ERROR: AssemblyAI transcription timed out after $max_polls polls" >&2
  log "AssemblyAI: Timeout for $transcript_id"
  return 1
}

# ═══════════════════════════════════════════════════════════
# LOCAL WHISPER TRANSCRIPTION (fallback)
# ═══════════════════════════════════════════════════════════
# Supports faster-whisper and openai-whisper.
# User must install and configure LOCAL_WHISPER_CMD.
#
# Usage: transcript=$(transcribe_local "/path/to/audio.mp3")
transcribe_local() {
  local audio_file="$1"

  if [ -z "$LOCAL_WHISPER_CMD" ]; then
    echo "ERROR: LOCAL_WHISPER_CMD not set. Install faster-whisper or openai-whisper." >&2
    echo "  pip install faster-whisper" >&2
    echo "  Then set: LOCAL_WHISPER_CMD=faster-whisper" >&2
    return 1
  fi

  if [ ! -f "$audio_file" ]; then
    echo "ERROR: Audio file not found: $audio_file" >&2
    return 1
  fi

  log "Local whisper: Transcribing $(basename "$audio_file") with $LOCAL_WHISPER_CMD"

  local basename_no_ext
  basename_no_ext=$(basename "$audio_file" | sed 's/\.[^.]*$//')

  case "$LOCAL_WHISPER_CMD" in
    faster-whisper|faster_whisper)
      # faster-whisper CLI
      if ! command -v faster-whisper &>/dev/null; then
        echo "ERROR: faster-whisper not found in PATH" >&2
        return 1
      fi
      faster-whisper "$audio_file" \
        --model "$LOCAL_WHISPER_MODEL" \
        --language "$LOCAL_WHISPER_LANGUAGE" \
        --output_dir "$TRANSCRIBE_TMP_DIR" \
        --output_format txt 2>>"$LOG_FILE" || return 1

      # faster-whisper outputs to <filename>.txt
      if [ -f "$TRANSCRIBE_TMP_DIR/${basename_no_ext}.txt" ]; then
        cat "$TRANSCRIBE_TMP_DIR/${basename_no_ext}.txt"
        return 0
      fi
      echo "ERROR: faster-whisper produced no output file" >&2
      return 1
      ;;
    whisper|openai-whisper)
      # OpenAI whisper CLI
      if ! command -v whisper &>/dev/null; then
        echo "ERROR: whisper not found in PATH" >&2
        return 1
      fi
      whisper "$audio_file" \
        --model "$LOCAL_WHISPER_MODEL" \
        --language "$LOCAL_WHISPER_LANGUAGE" \
        --output_dir "$TRANSCRIBE_TMP_DIR" \
        --output_format txt 2>>"$LOG_FILE" || return 1

      if [ -f "$TRANSCRIBE_TMP_DIR/${basename_no_ext}.txt" ]; then
        cat "$TRANSCRIBE_TMP_DIR/${basename_no_ext}.txt"
        return 0
      fi
      echo "ERROR: whisper produced no output file" >&2
      return 1
      ;;
    *)
      echo "ERROR: Unknown LOCAL_WHISPER_CMD: $LOCAL_WHISPER_CMD" >&2
      echo "  Supported: faster-whisper, whisper" >&2
      return 1
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════
# UNIFIED TRANSCRIBE FUNCTION
# ═══════════════════════════════════════════════════════════
# Dispatches to the configured backend with automatic fallback.
# Checks cache before hitting any API.
#
# Usage: transcript=$(transcribe_audio "/path/to/audio.mp3")
# Returns: transcript text on stdout, exits 1 if all backends fail
transcribe_audio() {
  local audio_file="$1"

  mkdir -p "$TRANSCRIBE_TMP_DIR"

  # Check cache first — avoid re-transcribing
  local cached
  cached=$(find_cached_transcript "$audio_file" 2>/dev/null) || true
  if [ -n "$cached" ]; then
    echo "$cached"
    return 0
  fi

  local transcript=""
  local rc=1

  case "$TRANSCRIBE_BACKEND" in
    assemblyai)
      transcript=$(transcribe_assemblyai "$audio_file") && rc=0 || rc=$?
      if [ $rc -ne 0 ]; then
        log "AssemblyAI failed, attempting local fallback..."
        echo "WARNING: AssemblyAI failed, trying local whisper fallback..." >&2
        transcript=$(transcribe_local "$audio_file") && rc=0 || rc=$?
      fi
      ;;
    local)
      transcript=$(transcribe_local "$audio_file") && rc=0 || rc=$?
      if [ $rc -ne 0 ]; then
        log "Local whisper failed, attempting AssemblyAI fallback..."
        echo "WARNING: Local whisper failed, trying AssemblyAI fallback..." >&2
        transcript=$(transcribe_assemblyai "$audio_file") && rc=0 || rc=$?
      fi
      ;;
    *)
      echo "ERROR: Unknown TRANSCRIBE_BACKEND: $TRANSCRIBE_BACKEND" >&2
      echo "  Supported: assemblyai, local" >&2
      return 1
      ;;
  esac

  # Cache on success
  if [ $rc -eq 0 ] && [ -n "$transcript" ]; then
    save_cached_transcript "$audio_file" "$transcript"
    echo "$transcript"
    return 0
  fi

  return 1
}

# ═══════════════════════════════════════════════════════════
# AUDIO DOWNLOAD HELPER
# ═══════════════════════════════════════════════════════════
# Downloads audio from a URL to a temp file.
# Handles direct MP3 URLs and platform URLs via yt-dlp.
#
# Usage: audio_path=$(download_audio "https://example.com/episode.mp3")
# Returns: path to downloaded file on stdout
download_audio() {
  local url="$1"
  local output_file="$TRANSCRIBE_TMP_DIR/audio_$(date +%s).mp3"

  mkdir -p "$TRANSCRIBE_TMP_DIR"

  # Detect if this is a direct audio file URL
  if [[ "$url" =~ \.(mp3|m4a|wav|ogg|flac|aac|wma)(\?|$) ]]; then
    log "Downloading direct audio: $url"
    curl -sfL -o "$output_file" --max-time 600 "$url" 2>>"$LOG_FILE" || true
  elif command -v yt-dlp &>/dev/null; then
    # Use yt-dlp for platform URLs (Spotify, Apple Podcasts, etc.)
    log "Downloading via yt-dlp: $url"
    yt-dlp -x --audio-format mp3 --audio-quality 5 \
      -o "$output_file" "$url" 2>>"$LOG_FILE" || true
  else
    # Try curl as last resort (may work for some podcast URLs)
    log "Downloading audio (no yt-dlp): $url"
    curl -sfL -o "$output_file" --max-time 600 "$url" 2>>"$LOG_FILE" || true
  fi

  if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
    echo "ERROR: Audio download failed: $url" >&2
    return 1
  fi

  log "Audio downloaded: $output_file ($(du -h "$output_file" | cut -f1))"
  echo "$output_file"
}
