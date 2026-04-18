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

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Guard common.sh against double-sourcing (extract.sh also sources it)
if [ -z "${_COMMON_SH_LOADED:-}" ]; then
  source "$SCRIPT_DIR/../lib/common.sh"
fi
source "$SCRIPT_DIR/../lib/extract.sh"

# Parse args (C4 fix)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault) VAULT_PATH="$2"; shift 2 ;;
    *)       shift ;;
  esac
done

EXTRACT_DIR="/tmp/extracted"
mkdir -p "$EXTRACT_DIR"

EXTRACT_TIMEOUT="${EXTRACT_TIMEOUT:-60}"
PARALLEL_JOBS="${EXTRACT_PARALLEL:-4}"

# Log helper: write to stderr so xargs stdout stays clean for parallel jobs
_log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# ═══════════════════════════════════════════════════════════
# EXTRACTION FUNCTIONS
# ═══════════════════════════════════════════════════════════

extract_youtube_transcript() {
  local video_id="$1"

  # TranscriptAPI (primary)
  if [ -n "${TRANSCRIPT_API_KEY:-}" ]; then
    local response
    response=$(curl -s --max-time "$EXTRACT_TIMEOUT" \
      "https://transcriptapi.com/api/v2/youtube/transcript?video_url=${video_id}&format=text&include_timestamp=true&send_metadata=true" \
      -H "Authorization: Bearer $TRANSCRIPT_API_KEY" 2>/dev/null)

    local http_code
    http_code=$(echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); print('200')" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
      echo "$response"
      return 0
    fi
  fi

  # Supadata (fallback)
  if [ -n "${SUPADATA_API_KEY:-}" ]; then
    local response
    response=$(curl -s --max-time "$EXTRACT_TIMEOUT" \
      "https://api.supadata.ai/v1/youtube/transcript?url=https://www.youtube.com/watch?v=${video_id}&text=true" \
      -H "x-api-key: $SUPADATA_API_KEY" 2>/dev/null)

    if [ -n "$response" ] && [ "${#response}" -gt 100 ]; then
      echo "$response"
      return 0
    fi
  fi

  return 1
}

extract_youtube_metadata() {
  local url="$1"
  curl -s "https://www.youtube.com/oembed?url=${url}&format=json" 2>/dev/null
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
    transcript_data=$(extract_youtube_transcript "$video_id" 2>/dev/null || true)
    if [ -n "$transcript_data" ]; then
      content=$(echo "$transcript_data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if 'transcript' in d:
    print(d['transcript'])
elif 'content' in d:
    print(d['content'])
else:
    print(json.dumps(d))
" 2>/dev/null || echo "$transcript_data")
    fi

    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      _log "WARN: YouTube transcript extraction failed for $video_id"
      content=$(printf "Title: %s\nAuthor: %s\nURL: %s\n\nNote: Full transcript unavailable (extraction failed)." "$title" "$author" "$url")
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
  echo "$content" > "/tmp/extracted/${url_hash}_content.tmp"
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
" "$url" "$title" "/tmp/extracted/${url_hash}_content.tmp" "$source_type" "${author:-unknown}" "$filename" "$outfile"

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
files = sorted(glob.glob('/tmp/extracted/*.json'))
manifest = []
for f in files:
    with open(f) as fh:
        d = json.load(fh)
        d['hash'] = os.path.basename(f).replace('.json','')
        manifest.append(d)
with open('/tmp/extracted/manifest.json', 'w') as fh:
    json.dump(manifest, fh, ensure_ascii=False, indent=2)
print(f'Manifest: {len(manifest)} entries')
"

echo "Extracted: $extracted | Failed: $failed"

# W11 fix: exit nonzero if nothing was extracted
if [ "$extracted" -eq 0 ] && [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
