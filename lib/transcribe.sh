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
# CONFIGURATION
# ═══════════════════════════════════════════════════════════
# Transcription backend: "assemblyai" or "local"
TRANSCRIBE_BACKEND="${TRANSCRIBE_BACKEND:-assemblyai}"

# AssemblyAI
ASSEMBLYAI_API_KEY="${ASSEMBLYAI_API_KEY:-}"
ASSEMBLYAI_API_URL="${ASSEMBLYAI_API_URL:-https://api.assemblyai.com}"

# Local whisper (not installed by default — user configures)
LOCAL_WHISPER_CMD="${LOCAL_WHISPER_CMD:-}"          # e.g., "faster-whisper" or "whisper"
LOCAL_WHISPER_MODEL="${LOCAL_WHISPER_MODEL:-large-v3}"
LOCAL_WHISPER_LANGUAGE="${LOCAL_WHISPER_LANGUAGE:-en}"

# Temp directory for audio downloads
TRANSCRIBE_TMP_DIR="${TRANSCRIBE_TMP_DIR:-/tmp/obsidian-transcribe}"

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
  local upload_url
  upload_url=$(curl -s -X POST "$ASSEMBLYAI_API_URL/v2/upload" \
    -H "Authorization: $ASSEMBLYAI_API_KEY" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$audio_file" \
    --max-time 300 2>>"$LOG_FILE" | grep -o '"upload_url":"[^"]*"' | cut -d'"' -f4)

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
    -d "{\"audio_url\": \"$upload_url\", \"punctuate\": true, \"format_text\": true}" \
    --max-time 30 2>>"$LOG_FILE")

  transcript_id=$(echo "$submit_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

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

    status=$(echo "$poll_response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

    case "$status" in
      completed)
        # Extract transcript text
        local text
        text=$(echo "$poll_response" | grep -o '"text":"[^"]*"' | cut -d'"' -f4)
        if [ -z "$text" ]; then
          # Try multiline extraction for longer transcripts
          text=$(echo "$poll_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('text',''))" 2>/dev/null || true)
        fi

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
        error_msg=$(echo "$poll_response" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)
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

  local output_file="$TRANSCRIBE_TMP_DIR/transcript_$(date +%s).txt"

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
        --output_format txt 2>>"$LOG_FILE"

      # faster-whisper outputs to <filename>.txt
      local basename_no_ext
      basename_no_ext=$(basename "$audio_file" | sed 's/\.[^.]*$//')
      cat "$TRANSCRIBE_TMP_DIR/${basename_no_ext}.txt" 2>/dev/null
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
        --output_format txt 2>>"$LOG_FILE"

      local basename_no_ext
      basename_no_ext=$(basename "$audio_file" | sed 's/\.[^.]*$//')
      cat "$TRANSCRIBE_TMP_DIR/${basename_no_ext}.txt" 2>/dev/null
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
#
# Usage: transcript=$(transcribe_audio "/path/to/audio.mp3")
# Returns: transcript text on stdout, exits 1 if all backends fail
transcribe_audio() {
  local audio_file="$1"

  mkdir -p "$TRANSCRIBE_TMP_DIR"

  case "$TRANSCRIBE_BACKEND" in
    assemblyai)
      if transcribe_assemblyai "$audio_file"; then
        return 0
      fi
      log "AssemblyAI failed, attempting local fallback..."
      echo "WARNING: AssemblyAI failed, trying local whisper fallback..." >&2
      transcribe_local "$audio_file"
      ;;
    local)
      if transcribe_local "$audio_file"; then
        return 0
      fi
      log "Local whisper failed, attempting AssemblyAI fallback..."
      echo "WARNING: Local whisper failed, trying AssemblyAI fallback..." >&2
      transcribe_assemblyai "$audio_file"
      ;;
    *)
      echo "ERROR: Unknown TRANSCRIBE_BACKEND: $TRANSCRIBE_BACKEND" >&2
      echo "  Supported: assemblyai, local" >&2
      return 1
      ;;
  esac
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
    curl -sL -o "$output_file" --max-time 600 "$url" 2>>"$LOG_FILE"
  elif command -v yt-dlp &>/dev/null; then
    # Use yt-dlp for platform URLs (Spotify, Apple Podcasts, etc.)
    log "Downloading via yt-dlp: $url"
    yt-dlp -x --audio-format mp3 --audio-quality 5 \
      -o "$output_file" "$url" 2>>"$LOG_FILE"
  else
    # Try curl as last resort (may work for some podcast URLs)
    log "Downloading audio (no yt-dlp): $url"
    curl -sL -o "$output_file" --max-time 600 "$url" 2>>"$LOG_FILE"
  fi

  if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
    echo "ERROR: Audio download failed: $url" >&2
    return 1
  fi

  log "Audio downloaded: $output_file ($(du -h "$output_file" | cut -f1))"
  echo "$output_file"
}
