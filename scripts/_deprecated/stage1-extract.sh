#!/usr/bin/env bash
# ============================================================================
# v2.1.0: Stage 1 — Batch Extract (no agent, pure shell)
# ============================================================================
# Extracts all URLs from the inbox and saves content to /tmp/extracted/.
# No LLM involved — defuddle, transcriptapi, curl only.
#
# Usage:
#   ./stage1-extract.sh [--vault PATH]
#
# Output: /tmp/extracted/{hash}.json per URL
#   Schema: {url, title, content, type, author, source_file}
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Guard common.sh against double-sourcing (extract.sh also sources it)
if [ -z "${_COMMON_SH_LOADED:-}" ]; then
  source "$SCRIPT_DIR/../lib/common.sh"
fi
source "$SCRIPT_DIR/../lib/extract.sh"

# Parse args — skip when sourced for parallel execution
if [ "${STAGE1_PARALLEL:-0}" != "1" ]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vault) VAULT_PATH="$2"; shift 2 ;;
      *)       shift ;;
    esac
  done
fi

EXTRACT_DIR="${PIPELINE_TMPDIR:-/tmp/extracted}"
mkdir -p "$EXTRACT_DIR"

EXTRACT_TIMEOUT="${EXTRACT_TIMEOUT:-60}"
PARALLEL_JOBS="${EXTRACT_PARALLEL:-4}"

# Log helper: write to stderr so xargs stdout stays clean for parallel jobs
_log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# ═══════════════════════════════════════════════════════════
# EXTRACTION FUNCTIONS
# ═══════════════════════════════════════════════════════════

extract_youtube_transcript() {
  local url="$1"
  local video_id="$2"

  # TranscriptAPI (primary) — MUST pass full URL, not bare video_id
  if [ -n "${TRANSCRIPT_API_KEY:-}" ]; then
    local response http_code
    response=$(curl -s --max-time "$EXTRACT_TIMEOUT" -w "\n%{http_code}" \
      "https://transcriptapi.com/api/v2/youtube/transcript?video_url=${url}&format=text&include_timestamp=true&send_metadata=true" \
      -H "Authorization: Bearer $TRANSCRIPT_API_KEY" 2>&1) || true

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ] && [ -n "$body" ] && [ "${#body}" -gt 50 ]; then
      echo "$body"
      return 0
    fi
    _log "TranscriptAPI returned HTTP $http_code for $video_id"
  fi

  # Supadata (fallback)
  if [ -n "${SUPADATA_API_KEY:-}" ]; then
    local response http_code
    response=$(curl -s --max-time "$EXTRACT_TIMEOUT" -w "\n%{http_code}" \
      -X POST "https://api.supadata.ai/v1/youtube/transcript" \
      -H "x-api-key: $SUPADATA_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"video_url\": \"https://www.youtube.com/watch?v=${video_id}\", \"format\": \"text\"}" 2>&1) || true

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ] && [ -n "$body" ] && [ "${#body}" -gt 50 ]; then
      echo "$body"
      return 0
    fi
    _log "Supadata returned HTTP $http_code for $video_id"
  fi

  # Whisper (last resort) — use faster-whisper Python module
  if command -v yt-dlp &>/dev/null; then
    if python3 -c "import faster_whisper" 2>/dev/null; then
      _log "Trying local Whisper for $video_id"
      local tmp_audio="/tmp/${video_id}_whisper_$(date +%s).mp3"
      if yt-dlp -x --audio-format mp3 --max-filesize 200M -o "$tmp_audio" "$url" 2>/dev/null; then
        local whisper_text
        whisper_text=$(python3 -c "
from faster_whisper import WhisperModel
import sys
model = WhisperModel('base', device='cpu', compute_type='int8')
segments, info = model.transcribe(sys.argv[1], language='en')
print(' '.join(s.text for s in segments))
" "$tmp_audio" 2>/dev/null) || true
        rm -f "$tmp_audio"
        if [ -n "$whisper_text" ] && [ "${#whisper_text}" -gt 50 ]; then
          echo "$whisper_text"
          return 0
        fi
        _log "Whisper returned empty/short transcript for $video_id"
      else
        _log "yt-dlp failed to download audio for $video_id"
        rm -f "$tmp_audio"
      fi
    fi
  fi

  return 1
}

extract_youtube_metadata() {
  local url="$1"
  curl -s "https://www.youtube.com/oembed?url=${url}&format=json" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════
# PODCAST EXTRACTION
# ═══════════════════════════════════════════════════════════

is_podcast_url() {
  [[ "$1" =~ podcasts\.apple\.com ]] || [[ "$1" =~ feeds\. ]] || [[ "$1" =~ podbean\.com ]] || [[ "$1" =~ anchor\.fm ]] || [[ "$1" =~ spotify\.com/episode ]]
}

# Extract Apple Podcast episode ID and lookup via iTunes API
extract_apple_podcast_info() {
  local url="$1"
  # Extract podcast ID and episode ID from URL like:
  # https://podcasts.apple.com/us/podcast/NAME/idPODCAST_ID?i=EPISODE_ID
  local podcast_id episode_id
  podcast_id=$(echo "$url" | grep -oP 'id\K[0-9]+' | head -1)
  episode_id=$(echo "$url" | grep -oP '[?&]i=\K[0-9]+' | head -1)

  if [ -z "$podcast_id" ]; then
    _log "Could not extract podcast ID from Apple Podcasts URL"
    return 1
  fi

  # iTunes Lookup API — returns podcast metadata + feed URL
  local lookup_response
  lookup_response=$(curl -s "https://itunes.apple.com/lookup?id=${podcast_id}&entity=podcast" 2>/dev/null) || true

  local feed_url podcast_name
  feed_url=$(echo "$lookup_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0].get('feedUrl',''))" 2>/dev/null || true)
  podcast_name=$(echo "$lookup_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0].get('collectionName',''))" 2>/dev/null || true)

  if [ -z "$feed_url" ]; then
    _log "iTunes Lookup returned no feed URL for podcast $podcast_id"
    return 1
  fi

  echo "${feed_url}|${podcast_name}|${episode_id}"
  return 0
}

# Parse RSS feed to find episode audio URL and description
extract_podcast_episode_from_rss() {
  local feed_url="$1"
  local episode_id="$2"
  local tmp_rss
  tmp_rss=$(mktemp /tmp/podcast-rss-XXXXXX.xml)

  if ! curl -sL --max-time 30 "$feed_url" -o "$tmp_rss" 2>/dev/null; then
    rm -f "$tmp_rss"
    return 1
  fi

  # Try to match by iTunes episode ID if available
  local audio_url description ep_title
  if [ -n "$episode_id" ]; then
    audio_url=$(python3 -c "
import xml.etree.ElementTree as ET, sys
tree = ET.parse('$tmp_rss')
for item in tree.iter('item'):
    eid = item.find('{http://www.itunes.com/dtds/podcast-1.0.dtd}episode')
    guid = item.find('guid')
    if guid is not None and '$episode_id' in (guid.text or ''):
        enclosure = item.find('enclosure')
        if enclosure is not None:
            print(enclosure.get('url', ''))
        break
    # Also check link
    link = item.find('link')
    if link is not None and '$episode_id' in (link.text or ''):
        enclosure = item.find('enclosure')
        if enclosure is not None:
            print(enclosure.get('url', ''))
        break
" 2>/dev/null || true)
  fi

  # Fallback: get the latest episode audio URL
  if [ -z "$audio_url" ]; then
    audio_url=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$tmp_rss')
for item in tree.iter('item'):
    enclosure = item.find('enclosure')
    if enclosure is not None:
        print(enclosure.get('url', ''))
        break
" 2>/dev/null || true)
  fi

  # Get episode description
  description=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$tmp_rss')
for item in tree.iter('item'):
    desc = item.find('description')
    if desc is not None and desc.text:
        print(desc.text[:5000])
        break
" 2>/dev/null || true)

  # Get episode title
  ep_title=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$tmp_rss')
for item in tree.iter('item'):
    title = item.find('title')
    if title is not None and title.text:
        print(title.text)
        break
" 2>/dev/null || true)

  rm -f "$tmp_rss"

  echo "${audio_url}|||SEPARATOR|||${description}|||SEPARATOR|||${ep_title}"
  return 0
}

extract_podcast_url() {
  local url="$1"
  local out_file="${2:-/tmp/podcast_extract_out.json}"

  _log "Extracting podcast: $url"

  local url_hash
  url_hash=$(echo -n "$url" | md5sum | cut -c1-12)

  local feed_url="" podcast_name="" episode_id="" audio_url="" description="" ep_title=""

  # Step 1: Get RSS feed URL via iTunes Lookup
  local apple_info
  apple_info=$(extract_apple_podcast_info "$url" 2>/dev/null || true)
  if [ -n "$apple_info" ]; then
    feed_url=$(echo "$apple_info" | cut -d'|' -f1)
    podcast_name=$(echo "$apple_info" | cut -d'|' -f2)
    episode_id=$(echo "$apple_info" | cut -d'|' -f3)
  fi

  # Step 2: Parse RSS for episode content
  if [ -n "$feed_url" ]; then
    local rss_data
    rss_data=$(extract_podcast_episode_from_rss "$feed_url" "$episode_id" 2>/dev/null || true)
    if [ -n "$rss_data" ]; then
      audio_url=$(echo "$rss_data" | cut -d'|' -f1)
      description=$(echo "$rss_data" | sed 's/.*|||SEPARATOR|||//' | cut -d'|' -f1)
      ep_title=$(echo "$rss_data" | sed 's/.*|||SEPARATOR|||.*|||SEPARATOR|||//')
    fi
  fi

  # Step 3: Try to transcribe audio if available
  local transcript=""
  if [ -n "$audio_url" ] && command -v yt-dlp &>/dev/null && command -v whisper &>/dev/null; then
    local tmp_audio
    tmp_audio=$(mktemp /tmp/podcast-audio-XXXXXX.mp3)
    _log "Downloading podcast audio for transcription..."
    if timeout 120 yt-dlp -x --audio-format mp3 -o "$tmp_audio" "$audio_url" 2>/dev/null; then
      _log "Transcribing podcast audio with Whisper..."
      if timeout 300 whisper "$tmp_audio" --model base --language en --output_format txt --output_dir /tmp/ 2>/dev/null; then
        local whisper_out="/tmp/$(basename "$tmp_audio" .mp3).txt"
        if [ -f "$whisper_out" ] && [ -s "$whisper_out" ]; then
          transcript=$(cat "$whisper_out")
          rm -f "$whisper_out"
        fi
      fi
    fi
    rm -f "$tmp_audio"
  fi

  # Step 4: Assemble content and write to JSON file
  local content=""
  if [ -n "$transcript" ] && [ "${#transcript}" -gt 100 ]; then
    content=$(printf "Podcast: %s\nEpisode: %s\nURL: %s\n\n## Transcript\n\n%s" \
      "${podcast_name}" "${ep_title}" "$url" "$transcript")
    _log "Podcast transcription OK (${#transcript} chars)"
  elif [ -n "$description" ] && [ "${#description}" -gt 100 ]; then
    content=$(printf "Podcast: %s\nEpisode: %s\nURL: %s\n\n## Description\n\n%s\n\nNote: Audio transcription unavailable. Description extracted from RSS feed." \
      "${podcast_name}" "${ep_title}" "$url" "$description")
    _log "Podcast: using RSS description (${#description} chars)"
  else
    content=$(printf "Podcast: %s\nEpisode: %s\nURL: %s\n\nNote: Could not extract transcript or description. Audio URL: %s" \
      "${podcast_name}" "${ep_title}" "$url" "${audio_url:-unavailable}")
    _log "WARN: Podcast extraction returned minimal content for $url"
  fi

  # Write structured output to file so caller doesn't have to parse multi-line stdout
  echo "$content" > "$EXTRACT_DIR/${url_hash:-podcast}_content.tmp"
  python3 -c "
import json, sys
data = {
    'content': open(sys.argv[1]).read(),
    'podcast_name': sys.argv[2],
    'episode_title': sys.argv[3],
    'audio_url': sys.argv[4]
}
with open(sys.argv[5], 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
" "$EXTRACT_DIR/${url_hash:-podcast}_content.tmp" "$podcast_name" "$ep_title" "$audio_url" "$out_file"
  rm -f "$EXTRACT_DIR/${url_hash:-podcast}_content.tmp"

  return 0
}

# ═══════════════════════════════════════════════════════════
# TITLE EXTRACTION
# ═══════════════════════════════════════════════════════════

extract_title_from_content() {
  local content="$1"

  # Try to find first markdown heading (# Title)
  local heading
  heading=$(echo "$content" | grep -m1 '^# ' | sed 's/^# //' | head -c 120)

  if [ -n "$heading" ] && [ "${#heading}" -gt 5 ] && [[ "$heading" != "Original content"* ]]; then
    echo "$heading"
    return 0
  fi

  # Try first meaningful sentence (>20 chars, not a URL or image)
  local sentence
  sentence=$(echo "$content" | grep -v '^!' | grep -v '^http' | grep -v '^\[' | grep -m1 '[a-zA-Z]' | head -c 120)

  if [ -n "$sentence" ] && [ "${#sentence}" -gt 20 ]; then
    echo "$sentence"
    return 0
  fi

  return 1
}

# ═══════════════════════════════════════════════════════════
# SINGLE-URL EXTRACTION (runs in parallel)
# ═══════════════════════════════════════════════════════════

extract_single_url() {
  local url_file="$1"

  local filename url url_hash outfile
  filename=$(basename "$url_file")
  url=$(cat "$url_file" | tr -d '\r\n')
  url_hash=$(echo -n "$url" | md5sum | cut -c1-12)
  outfile="$EXTRACT_DIR/${url_hash}.json"

  # Skip if already extracted
  if [ -f "$outfile" ]; then
    _log "SKIP (already extracted): $filename"
    echo "SKIP|$url_hash"  # status line for aggregator
    return 0
  fi

  # Atomic lock: prevent duplicate URLs from concurrent extraction
  local lockfile="$EXTRACT_DIR/.lock_${url_hash}"
  if ! mkdir "$lockfile" 2>/dev/null; then
    _log "SKIP (another process extracting $url_hash): $filename"
    echo "SKIP|$url_hash"
    return 0
  fi
  trap 'rmdir "$lockfile" 2>/dev/null' RETURN

  _log "Extracting: $filename → $url"

  local content="" title="" author="" source_type=""

  # Route by URL type
  if [[ "$url" =~ youtu(\.be|be\.com) ]]; then
    # ── YouTube ──
    source_type="youtube"
    local video_id
    video_id=$(echo "$url" | sed -n 's/.*[?&]v=\([a-zA-Z0-9_-]\{11\}\).*/\1/p; s/.*youtu\.be\/\([a-zA-Z0-9_-]\{11\}\).*/\1/p; s/.*shorts\/\([a-zA-Z0-9_-]\{11\}\).*/\1/p' | head -1)

    if [ -z "$video_id" ]; then
      video_id=$(echo "$url" | python3 -c "import re,sys; m=re.search(r'[a-zA-Z0-9_-]{11}', sys.stdin.read()); print(m.group() if m else '')" 2>/dev/null || true)
    fi

    local yt_meta
    yt_meta=$(extract_youtube_metadata "$url")
    title=$(echo "$yt_meta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null || true)
    author=$(echo "$yt_meta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('author_name',''))" 2>/dev/null || true)

    local transcript_data
    transcript_data=$(extract_youtube_transcript "$url" "$video_id" 2>/dev/null || true)
    if [ -n "$transcript_data" ]; then
      content=$(echo "$transcript_data" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if 'transcript' in d:
        print(d['transcript'])
    elif 'content' in d:
        print(d['content'])
    else:
        print(json.dumps(d))
except:
    print(sys.stdin.read())
" 2>/dev/null || echo "$transcript_data")
    fi

    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      _log "WARN: YouTube transcript extraction failed for $video_id"
      content=$(printf "Title: %s\nAuthor: %s\nURL: %s\n\nNote: Full transcript unavailable (extraction failed)." "$title" "$author" "$url")
    fi

  elif is_podcast_url "$url"; then
    # ── Podcast ──
    source_type="podcast"
    local podcast_json="$EXTRACT_DIR/${url_hash}_podcast.json"
    extract_podcast_url "$url" "$podcast_json" 2>/dev/null || true

    if [ -f "$podcast_json" ]; then
      content=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('content',''))" "$podcast_json" 2>/dev/null || true)
      author=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('podcast_name',''))" "$podcast_json" 2>/dev/null || true)
      local ep_title
      ep_title=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('episode_title',''))" "$podcast_json" 2>/dev/null || true)
      if [ -n "$ep_title" ]; then
        title="$ep_title"
      fi
      rm -f "$podcast_json"
    fi

    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      _log "WARN: Podcast extraction failed for $url"
      content=$(printf "URL: %s\n\nNote: Podcast extraction failed." "$url")
    fi

  elif [[ "$url" =~ x\.com/ ]]; then
    # ── X/Twitter — use extract_web from extract.sh (W10: use library) ──
    source_type="twitter"
    content=$(extract_web "$url" 2>/dev/null || true)
    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      content=$(timeout "$EXTRACT_TIMEOUT" defuddle parse "$url" --md 2>/dev/null || true)
    fi
    author=$(echo "$url" | python3 -c "import re,sys; m=re.search(r'x\.com/([^/]+)', sys.stdin.read()); print(m.group(1) if m else 'unknown')" 2>/dev/null || echo "unknown")

    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      _log "WARN: Tweet extraction failed for $url"
      content=$(printf "Author: @%s\nURL: %s\n\nNote: Content extraction failed." "$author" "$url")
    fi

  else
    # ── Blog / Generic URL — use extract_web from extract.sh (W10) ──
    source_type="web"
    content=$(extract_web "$url" 2>/dev/null || true)
    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      content=$(timeout "$EXTRACT_TIMEOUT" defuddle parse "$url" --md 2>/dev/null || true)
    fi

    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      _log "WARN: Blog extraction failed for $url"
      content=$(printf "URL: %s\n\nNote: Content extraction failed." "$url")
    fi
  fi

  # Extract title from content if not already set
  if [ -z "$title" ]; then
    title=$(extract_title_from_content "$content" 2>/dev/null || true)
  fi
  if [ -z "$title" ]; then
    title="$filename"
  fi

  # Save as JSON — write content to temp file to avoid "Argument list too long"
  echo "$content" > "$EXTRACT_DIR/${url_hash}_content.tmp"
  python3 -c "
import json, sys, os
data = {
    'url': sys.argv[1],
    'title': sys.argv[2],
    'content': open(sys.argv[3]).read(),
    'type': sys.argv[4],
    'author': sys.argv[5],
    'source_file': sys.argv[6]
}
with open(sys.argv[7], 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
os.unlink(sys.argv[3])
" "$url" "$title" "$EXTRACT_DIR/${url_hash}_content.tmp" "$source_type" "${author:-unknown}" "$filename" "$outfile"

  if [ -f "$outfile" ] && [ -s "$outfile" ]; then
    _log "OK: $filename → $outfile (${#content} chars)"
    echo "OK|$url_hash"
  else
    _log "FAIL: $filename — could not create extraction output"
    echo "FAIL|$url_hash"
  fi
}

# ═══════════════════════════════════════════════════════════
# If sourced for parallel subshell execution, stop here (only functions needed)
if [ "${STAGE1_PARALLEL:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# Export env vars for xargs subshells
export EXTRACT_DIR EXTRACT_TIMEOUT VAULT_PATH

# ═══════════════════════════════════════════════════════════
# PARALLEL EXTRACTION
# ═══════════════════════════════════════════════════════════

_log "=== Stage 1: Batch Extract (parallel=$PARALLEL_JOBS) ==="

# Collect all .url files
url_files=()
for file in "$VAULT_PATH/01-Raw"/*.url; do
  [ -f "$file" ] || continue
  url_files+=("$file")
done

total_urls=${#url_files[@]}
_log "Found $total_urls URLs to extract"

if [ "$total_urls" -eq 0 ]; then
  _log "No .url files found in inbox"
  echo "Extracted: 0 | Failed: 0"
  exit 0
fi

# Run extraction in parallel, collect status lines
# Each subshell sources this same script file to get extract_single_url function,
# then calls it with the URL file argument. Status goes to stdout for aggregation.
mapfile -t status_lines < <(
  printf '%s\n' "${url_files[@]}" | \
  xargs -I{} -P "$PARALLEL_JOBS" bash -c '
    # Source this same script to get the function definitions
    # (only the function definitions run; the main body is guarded by STAGE1_PARALLEL)
    export STAGE1_PARALLEL=1
    source "$0"
    extract_single_url "$1"
  ' "$0" {}
)

# ═══════════════════════════════════════════════════════════
# AGGREGATE RESULTS
# ═══════════════════════════════════════════════════════════

extracted=0
failed=0

for status in "${status_lines[@]}"; do
  case "$status" in
    OK\|*)     extracted=$((extracted + 1)) ;;
    FAIL\|*)   failed=$((failed + 1)) ;;
    SKIP\|*)   extracted=$((extracted + 1)) ;;  # already extracted counts as success
  esac
done

_log "=== Stage 1 complete: $extracted extracted, $failed failed ==="

# Write manifest (skip .tmp files)
python3 -c "
import json, glob, os
extract_dir = os.environ.get('EXTRACT_DIR', '/tmp/extracted')
files = sorted(glob.glob(os.path.join(extract_dir, '*.json')))
manifest = []
for f in files:
    with open(f) as fh:
        d = json.load(fh)
        d['hash'] = os.path.basename(f).replace('.json','')
        manifest.append(d)
with open(os.path.join(extract_dir, 'manifest.json'), 'w') as fh:
    json.dump(manifest, fh, ensure_ascii=False, indent=2)
print(f'Manifest: {len(manifest)} entries')
"

echo "Extracted: $extracted | Failed: $failed"

# W11 fix: exit nonzero if nothing was extracted
if [ "$extracted" -eq 0 ] && [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
