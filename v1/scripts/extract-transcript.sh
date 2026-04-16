#!/usr/bin/env bash
#
# Universal Transcript Extraction Script
# Implements the full hierarchy: existing → API fallbacks → local processing
#
# Usage:
#   ./extract-transcript.sh youtube VIDEO_URL
#   ./extract-transcript.sh podcast AUDIO_FILE [--name "Podcast Name"] [--episode "Episode Title"]
#   ./extract-transcript.sh podcast --rss RSS_URL --episode EPISODE_ID
#
# Output: Markdown formatted transcript saved to cache and stdout

set -euo pipefail

# Configuration
CACHE_DIR="${HOME}/.hermes/cache/transcripts"
VAULT_DIR="${HOME}/MyVault"
LOG_FILE="${CACHE_DIR}/extraction.log"

# API Keys (from environment)
TRANSCRIPT_API_KEY="${TRANSCRIPT_API_KEY:-}"
SUPADATA_API_KEY="${SUPADATA_API_KEY:-}"
ASSEMBLYAI_API_KEY="${ASSEMBLYAI_API_KEY:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level=$1
    shift
    echo -e "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [$level] $*" | tee -a "$LOG_FILE"
}

# Check dependencies
check_deps() {
    local deps=("curl" "jq" "date")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log "ERROR" "Missing dependency: $dep"
            exit 1
        fi
    done
}

# Create cache directory
setup_cache() {
    mkdir -p "$CACHE_DIR/youtube"
    mkdir -p "$CACHE_DIR/podcasts"
    touch "$LOG_FILE"
}

# Extract YouTube video ID from URL
extract_video_id() {
    local url=$1
    echo "$url" | grep -oP '(?:v=|youtu\.be/|shorts/)([a-zA-Z0-9_-]{11})' | head -1 | sed 's/v=\|youtu\.be\/\|shorts\///'
}

# Check for existing transcript in vault
check_existing_transcript() {
    local search_term=$1
    local cache_key=$2
    
    log "INFO" "Checking for existing transcript: $search_term"
    
    # Check cache first
    if [[ -f "$CACHE_DIR/$cache_key.json" ]]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$CACHE_DIR/$cache_key.json" 2>/dev/null || echo 0)))
        if [[ $cache_age -lt 2592000 ]]; then  # 30 days
            log "INFO" "Found cached transcript ($(($cache_age / 86400)) days old)"
            cat "$CACHE_DIR/$cache_key.json"
            return 0
        fi
    fi
    
    # Search vault
    local results=$(find "$VAULT_DIR" -name "*.md" -exec grep -l "$search_term" {} \; 2>/dev/null | head -5)
    if [[ -n "$results" ]]; then
        log "INFO" "Found in vault: $results"
        echo "$results" | head -1 | xargs cat
        return 0
    fi
    
    return 1
}

# YouTube: TranscriptAPI (Primary)
youtube_transcriptapi() {
    local video_url=$1
    local video_id=$2
    
    log "INFO" "Trying TranscriptAPI for video: $video_id"
    
    if [[ -z "$TRANSCRIPT_API_KEY" ]]; then
        log "WARN" "TRANSCRIPT_API_KEY not set, skipping"
        return 1
    fi
    
    local response=$(curl -s -w "\n%{http_code}" \
        "https://transcriptapi.com/api/v2/youtube/transcript?video_url=${video_url}&format=text&include_timestamp=true&send_metadata=true" \
        -H "Authorization: Bearer $TRANSCRIPT_API_KEY")
    
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | head -n -1)
    
    if [[ "$http_code" -eq 200 ]]; then
        log "INFO" "TranscriptAPI success"
        echo "$body" > "$CACHE_DIR/youtube/${video_id}.json"
        echo "$body"
        return 0
    else
        log "WARN" "TranscriptAPI failed with HTTP $http_code"
        return 1
    fi
}

# YouTube: Supadata (Fallback)
youtube_supadata() {
    local video_id=$1
    
    log "INFO" "Trying Supadata for video: $video_id"
    
    if [[ -z "$SUPADATA_API_KEY" ]]; then
        log "WARN" "SUPADATA_API_KEY not set, skipping"
        return 1
    fi
    
    local response=$(curl -s -w "\n%{http_code}" \
        -X POST "https://api.supadata.ai/v1/youtube/transcript" \
        -H "Authorization: Bearer $SUPADATA_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"video_id\": \"$video_id\", \"format\": \"text\"}")
    
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | head -n -1)
    
    if [[ "$http_code" -eq 200 ]]; then
        log "INFO" "Supadata success"
        echo "$body" > "$CACHE_DIR/youtube/${video_id}.json"
        echo "$body"
        return 0
    else
        log "WARN" "Supadata failed with HTTP $http_code"
        return 1
    fi
}

# YouTube: Local Whisper (Last Resort)
youtube_whisper() {
    local video_url=$1
    local video_id=$2
    
    log "INFO" "Trying local Whisper for video: $video_id"
    
    if ! command -v whisper &> /dev/null; then
        log "ERROR" "Whisper not installed"
        return 1
    fi
    
    if ! command -v yt-dlp &> /dev/null; then
        log "ERROR" "yt-dlp not installed"
        return 1
    fi
    
    local temp_audio="/tmp/${video_id}.mp3"
    
    log "INFO" "Downloading audio..."
    if ! yt-dlp -x --audio-format mp3 -o "$temp_audio" "$video_url" 2>> "$LOG_FILE"; then
        log "ERROR" "Failed to download audio"
        return 1
    fi
    
    log "INFO" "Transcribing with Whisper (this may take a while)..."
    if ! whisper "$temp_audio" \
        --model medium \
        --language en \
        --output_format txt \
        --output_dir "$CACHE_DIR/youtube/" 2>> "$LOG_FILE"; then
        log "ERROR" "Whisper transcription failed"
        rm -f "$temp_audio"
        return 1
    fi
    
    # Rename output file
    mv "$CACHE_DIR/youtube/${video_id}.txt" "$CACHE_DIR/youtube/${video_id}.json" 2>/dev/null || true
    
    rm -f "$temp_audio"
    log "INFO" "Whisper transcription complete"
    
    cat "$CACHE_DIR/youtube/${video_id}.json"
    return 0
}

# Podcast: AssemblyAI
podcast_assemblyai() {
    local audio_file=$1
    local podcast_name=$2
    local episode_title=$3
    
    log "INFO" "Trying AssemblyAI for podcast: $podcast_name - $episode_title"
    
    if [[ -z "$ASSEMBLYAI_API_KEY" ]]; then
        log "ERROR" "ASSEMBLYAI_API_KEY not set"
        return 1
    fi
    
    if [[ ! -f "$audio_file" ]]; then
        log "ERROR" "Audio file not found: $audio_file"
        return 1
    fi
    
    # Upload audio
    log "INFO" "Uploading audio file..."
    local upload_response=$(curl -s -X POST "https://api.assemblyai.com/v2/upload" \
        -H "Authorization: $ASSEMBLYAI_API_KEY" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$audio_file")
    
    local upload_url=$(echo "$upload_response" | jq -r '.upload_url // empty')
    
    if [[ -z "$upload_url" ]]; then
        log "ERROR" "Failed to upload audio"
        return 1
    fi
    
    # Request transcription
    log "INFO" "Requesting transcription..."
    local transcript_response=$(curl -s -X POST "https://api.assemblyai.com/v2/transcript" \
        -H "Authorization: $ASSEMBLYAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"audio_url\": \"$upload_url\", \"speaker_labels\": true}")
    
    local transcript_id=$(echo "$transcript_response" | jq -r '.id // empty')
    
    if [[ -z "$transcript_id" ]]; then
        log "ERROR" "Failed to create transcription job"
        return 1
    fi
    
    # Poll for completion
    log "INFO" "Waiting for transcription (ID: $transcript_id)..."
    local status=""
    while true; do
        status=$(curl -s "https://api.assemblyai.com/v2/transcript/$transcript_id" \
            -H "Authorization: $ASSEMBLYAI_API_KEY" | jq -r '.status')
        
        if [[ "$status" == "completed" ]]; then
            break
        elif [[ "$status" == "error" ]]; then
            log "ERROR" "Transcription failed"
            return 1
        fi
        
        sleep 5
    done
    
    # Get final transcript
    local final_response=$(curl -s "https://api.assemblyai.com/v2/transcript/$transcript_id" \
        -H "Authorization: $ASSEMBLYAI_API_KEY")
    
    local cache_key="podcasts/$(echo "${podcast_name}_${episode_title}" | md5sum | cut -d' ' -f1)"
    echo "$final_response" > "$CACHE_DIR/${cache_key}.json"
    
    echo "$final_response" | jq -r '.text'
    return 0
}

# Format YouTube transcript as Markdown
format_youtube_markdown() {
    local title=$1
    local url=$2
    local method=$3
    local transcript=$4
    local metadata=$5
    
    cat << EOF
# $title
**Source:** $url
**Extracted:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Method:** $method

## Transcript
$transcript

---
*Extracted via $method*
EOF
}

# Format podcast transcript as Markdown
format_podcast_markdown() {
    local podcast_name=$1
    local episode_title=$2
    local source=$3
    local method=$4
    local transcript=$5
    
    cat << EOF
# $podcast_name - $episode_title
**Source:** $source
**Extracted:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Method:** $method

## Transcript
$transcript

---
*Extracted via $method*
EOF
}

# Main YouTube extraction workflow
extract_youtube() {
    local video_url=$1
    local video_id=$(extract_video_id "$video_url")
    
    if [[ -z "$video_id" ]]; then
        log "ERROR" "Could not extract video ID from URL: $video_url"
        exit 1
    fi
    
    log "INFO" "Extracting YouTube transcript for video: $video_id"
    
    # Step 0: Check existing
    local existing=$(check_existing_transcript "$video_id" "youtube/$video_id" || true)
    if [[ -n "$existing" ]]; then
        format_youtube_markdown "YouTube Video" "$video_url" "existing" "$existing" ""
        return 0
    fi
    
    # Step 1: TranscriptAPI
    local transcript=$(youtube_transcriptapi "$video_url" "$video_id" || true)
    if [[ -n "$transcript" ]]; then
        format_youtube_markdown "YouTube Video" "$video_url" "transcriptapi" "$transcript" ""
        return 0
    fi
    
    # Step 2: Supadata
    transcript=$(youtube_supadata "$video_id" || true)
    if [[ -n "$transcript" ]]; then
        format_youtube_markdown "YouTube Video" "$video_url" "supadata" "$transcript" ""
        return 0
    fi
    
    # Step 3: Whisper
    transcript=$(youtube_whisper "$video_url" "$video_id" || true)
    if [[ -n "$transcript" ]]; then
        format_youtube_markdown "YouTube Video" "$video_url" "whisper" "$transcript" ""
        return 0
    fi
    
    log "ERROR" "All YouTube extraction methods failed"
    exit 1
}

# Main podcast extraction workflow
extract_podcast() {
    local source=$1
    local podcast_name="Unknown Podcast"
    local episode_title="Unknown Episode"
    local audio_file=""
    
    shift
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                podcast_name="$2"
                shift 2
                ;;
            --episode)
                episode_title="$2"
                shift 2
                ;;
            --rss)
                # TODO: Implement RSS feed parsing
                log "ERROR" "RSS feed parsing not yet implemented"
                exit 1
                ;;
            *)
                audio_file="$1"
                shift
                ;;
        esac
    done
    
    if [[ -z "$audio_file" ]]; then
        log "ERROR" "No audio file specified"
        exit 1
    fi
    
    log "INFO" "Extracting podcast transcript: $podcast_name - $episode_title"
    
    # Step 0: Check existing
    local cache_key=$(echo "${podcast_name}_${episode_title}" | md5sum | cut -d' ' -f1)
    local existing=$(check_existing_transcript "$episode_title" "podcasts/$cache_key" || true)
    if [[ -n "$existing" ]]; then
        format_podcast_markdown "$podcast_name" "$episode_title" "$source" "existing" "$existing"
        return 0
    fi
    
    # Step 1: AssemblyAI
    local transcript=$(podcast_assemblyai "$audio_file" "$podcast_name" "$episode_title" || true)
    if [[ -n "$transcript" ]]; then
        format_podcast_markdown "$podcast_name" "$episode_title" "$source" "assemblyai" "$transcript"
        return 0
    fi
    
    log "ERROR" "All podcast extraction methods failed"
    exit 1
}

# Main entry point
main() {
    check_deps
    setup_cache
    
    if [[ $# -lt 2 ]]; then
        echo "Usage:"
        echo "  $0 youtube VIDEO_URL"
        echo "  $0 podcast AUDIO_FILE [--name \"Podcast Name\"] [--episode \"Episode Title\"]"
        echo "  $0 podcast --rss RSS_URL --episode EPISODE_ID"
        exit 1
    fi
    
    local content_type=$1
    shift
    
    case $content_type in
        youtube)
            extract_youtube "$1"
            ;;
        podcast)
            extract_podcast "$@"
            ;;
        *)
            log "ERROR" "Unknown content type: $content_type"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"