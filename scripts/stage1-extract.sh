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
extracted=0
failed=0

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
# MAIN EXTRACTION LOOP
# ═══════════════════════════════════════════════════════════

log "=== Stage 1: Batch Extract ==="

for file in "$VAULT_PATH/01-Raw"/*.url; do
  [ -f "$file" ] || continue

  filename=$(basename "$file")
  url=$(cat "$file" | tr -d '\r\n')

  # Generate hash for dedup
  url_hash=$(echo -n "$url" | md5sum | cut -c1-12)
  outfile="$EXTRACT_DIR/${url_hash}.json"

  # Skip if already extracted
  if [ -f "$outfile" ]; then
    log "SKIP (already extracted): $filename"
    continue
  fi

  log "Extracting: $filename → $url"

  content=""
  title=""
  author=""
  source_type=""

  # Route by URL type
  if [[ "$url" =~ youtu(\.be|be\.com) ]]; then
    # ── YouTube ──
    source_type="youtube"
    # Use sed for portability (W6: grep -oP is GNU-only)
    video_id=$(echo "$url" | sed -n 's/.*[?&]v=\([a-zA-Z0-9_-]\{11\}\).*/\1/p; s/.*youtu\.be\/\([a-zA-Z0-9_-]\{11\}\).*/\1/p; s/.*shorts\/\([a-zA-Z0-9_-]\{11\}\).*/\1/p' | head -1)

    if [ -z "$video_id" ]; then
      # Fallback: python3 regex (portable, more permissive)
      video_id=$(echo "$url" | python3 -c "import re,sys; m=re.search(r'[a-zA-Z0-9_-]{11}', sys.stdin.read()); print(m.group() if m else '')" 2>/dev/null || true)
    fi

    # Get metadata
    yt_meta=$(extract_youtube_metadata "$url")
    title=$(echo "$yt_meta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null || true)
    author=$(echo "$yt_meta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('author_name',''))" 2>/dev/null || true)

    # Get transcript
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
      log "WARN: YouTube transcript extraction failed for $video_id"
      content=$(printf "Title: %s\nAuthor: %s\nURL: %s\n\nNote: Full transcript unavailable (extraction failed)." "$title" "$author" "$url")
    fi

  elif [[ "$url" =~ x\.com/ ]]; then
    # ── X/Twitter — use extract_web from extract.sh (W10: use library) ──
    source_type="twitter"
    content=$(extract_web "$url" 2>/dev/null || true)
    # Fallback to direct defuddle if extract_web fails
    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      content=$(timeout "$EXTRACT_TIMEOUT" defuddle parse "$url" --md 2>/dev/null || true)
    fi
    # Use python3 for portable regex (W6 fix)
    author=$(echo "$url" | python3 -c "import re,sys; m=re.search(r'x\.com/([^/]+)', sys.stdin.read()); print(m.group(1) if m else 'unknown')" 2>/dev/null || echo "unknown")

    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      log "WARN: Tweet extraction failed for $url"
      content=$(printf "Author: @%s\nURL: %s\n\nNote: Content extraction failed." "$author" "$url")
    fi

  else
    # ── Blog / Generic URL — use extract_web from extract.sh (W10) ──
    source_type="web"
    content=$(extract_web "$url" 2>/dev/null || true)
    # Fallback: direct defuddle
    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      content=$(timeout "$EXTRACT_TIMEOUT" defuddle parse "$url" --md 2>/dev/null || true)
    fi

    if [ -z "$content" ] || [ "${#content}" -lt 50 ]; then
      log "WARN: Blog extraction failed for $url"
      content=$(printf "URL: %s\n\nNote: Content extraction failed." "$url")
    fi
  fi

  # Extract title from content if not already set
  if [ -z "$title" ]; then
    title=$(extract_title_from_content "$content" 2>/dev/null || true)
  fi

  # Fallback title
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
    extracted=$((extracted + 1))
    log "OK: $filename → $outfile (${#content} chars)"
  else
    failed=$((failed + 1))
    log "FAIL: $filename — could not create extraction output"
  fi
done

log "=== Stage 1 complete: $extracted extracted, $failed failed ==="

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
