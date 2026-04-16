#!/usr/bin/env bash
# ============================================================================
# v2.2: Extraction Library — Content extraction with failover
# ============================================================================
# Source this file: source lib/extract.sh
#
# Priority chains:
#   arxiv.org → arxiv HTML (defuddle) → alphaxiv → defuddle → liteparse → tavily
#   URL/HTML/X → defuddle → liteparse (url mode) → tavily/web search → screenshot
#   PDF/DOCX/PPTX/XLSX → liteparse (local) → ocr-and-documents → browser
#
# Dependencies: defuddle, liteparse (both in PATH)
# ============================================================================

_EXTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EXTRACT_DIR/common.sh"

# ═══════════════════════════════════════════════════════════
# ARXIV / ALPHAXIV EXTRACTION (special handling for papers)
# ═══════════════════════════════════════════════════════════
# For arxiv papers, use alphaxiv.org which provides full extracted text.
# Falls back to defuddle if alphaxiv fails.

is_arxiv_url() {
  local url="$1"
  [[ "$url" =~ arxiv\.org/(abs|pdf|html)/[0-9]{4}\.[0-9]{4,5} ]]
}

extract_arxiv_paper_id() {
  local url="$1"
  # Extract paper ID: 2503.03312 from various arxiv URL formats
  echo "$url" | grep -oP '[0-9]{4}\.[0-9]{4,5}' | head -1
}

extract_arxiv_alphaxiv() {
  local url="$1"
  local paper_id
  paper_id=$(extract_arxiv_paper_id "$url")
  if [ -z "$paper_id" ]; then
    log "extract_arxiv_alphaxiv: could not extract paper ID from $url"
    return 1
  fi

  log "extract_arxiv_alphaxiv: fetching full text for $paper_id via alphaxiv"
  
  # Try full text endpoint first (alphaxiv.org/abs/{ID}.md)
  local content
  content=$(curl -sL "https://www.alphaxiv.org/abs/${paper_id}.md" 2>/dev/null)
  if [ -n "$content" ] && [ "${#content}" -gt 500 ]; then
    log "extract_arxiv_alphaxiv: full text OK (${#content} chars)"
    echo "$content"
    return 0
  fi

  # Fallback: try overview/report endpoint
  content=$(curl -sL "https://www.alphaxiv.org/overview/${paper_id}.md" 2>/dev/null)
  if [ -n "$content" ] && [ "${#content}" -gt 200 ] && [[ "$content" != *"No intermediate report"* ]]; then
    log "extract_arxiv_alphaxiv: overview report OK (${#content} chars)"
    echo "$content"
    return 0
  fi

  log "extract_arxiv_alphaxiv: alphaxiv failed for $paper_id, falling back to defuddle"
  return 1
}

# ═══════════════════════════════════════════════════════════
# WEB / URL / HTML / X-TWITTER EXTRACTION
# ═══════════════════════════════════════════════════════════
# Chain: defuddle → liteparse (url) → tavily extract → web search → screenshot
#
# Usage: content=$(extract_web "$url")
# Returns: markdown content on stdout, exits 1 if all methods fail

extract_web() {
  local url="$1"
  local output=""
  local rc=1

  log "extract_web: attempting extraction for $url"

  # ── Tier 0: Arxiv papers → HTML version (full text via defuddle) → alphaxiv ──
  if is_arxiv_url "$url"; then
    # Try arxiv HTML first (same domain, defuddle handles it well)
    local html_url
    local paper_id
    paper_id=$(extract_arxiv_paper_id "$url")
    if [ -n "$paper_id" ]; then
      html_url="https://arxiv.org/html/${paper_id}v1"
      output=$(extract_web_defuddle "$html_url") && rc=0 || rc=$?
      if [ $rc -eq 0 ] && [ -n "$output" ] && [ "${#output}" -gt 500 ]; then
        log "extract_web: arxiv HTML succeeded for $html_url (${#output} chars)"
        echo "$output"
        return 0
      fi
    fi
    # Fallback: alphaxiv full text
    output=$(extract_arxiv_alphaxiv "$url") && rc=0 || rc=$?
    if [ $rc -eq 0 ] && [ -n "$output" ] && [ "${#output}" -gt 500 ]; then
      log "extract_web: alphaxiv succeeded for $url (${#output} chars)"
      echo "$output"
      return 0
    fi
    log "extract_web: alphaxiv failed for arxiv URL $url, falling back to defuddle..."
  fi

  # ── Tier 1: Defuddle (clean markdown from web pages) ──
  output=$(extract_web_defuddle "$url") && rc=0 || rc=$?
  if [ $rc -eq 0 ] && [ -n "$output" ] && [ "${#output}" -gt 200 ]; then
    log "extract_web: defuddle succeeded for $url (${#output} chars)"
    echo "$output"
    return 0
  fi
  log "extract_web: defuddle failed or too short for $url, trying liteparse..."

  # ── Tier 2: Liteparse (download page, parse as document) ──
  output=$(extract_web_liteparse "$url") && rc=0 || rc=$?
  if [ $rc -eq 0 ] && [ -n "$output" ] && [ "${#output}" -gt 200 ]; then
    log "extract_web: liteparse succeeded for $url (${#output} chars)"
    echo "$output"
    return 0
  fi
  log "extract_web: liteparse failed for $url, trying tavily/web search..."

  # ── Tier 3: Tavily extract (web search API) ──
  output=$(extract_web_tavily "$url") && rc=0 || rc=$?
  if [ $rc -eq 0 ] && [ -n "$output" ] && [ "${#output}" -gt 200 ]; then
    log "extract_web: tavily succeeded for $url (${#output} chars)"
    echo "$output"
    return 0
  fi
  log "extract_web: tavily failed for $url, trying browser screenshot..."

  # ── Tier 4: Browser screenshot (last resort) ──
  output=$(extract_web_screenshot "$url") && rc=0 || rc=$?
  if [ $rc -eq 0 ] && [ -n "$output" ]; then
    log "extract_web: screenshot fallback succeeded for $url"
    echo "$output"
    return 0
  fi

  log "extract_web: ALL extraction methods failed for $url"
  return 1
}

# Defuddle: clean markdown extraction from URL
extract_web_defuddle() {
  local url="$1"
  if ! command -v defuddle &>/dev/null; then
    log "extract_web_defuddle: defuddle not found in PATH"
    return 1
  fi

  local tmpfile
  tmpfile=$(mktemp /tmp/defuddle-XXXXXX.md)

  # defuddle parse --markdown <url> -o <output>
  if defuddle parse --markdown "$url" -o "$tmpfile" 2>/dev/null; then
    if [ -s "$tmpfile" ]; then
      cat "$tmpfile"
      rm -f "$tmpfile"
      return 0
    fi
  fi

  # Try JSON mode for metadata extraction
  local json_out
  json_out=$(defuddle parse --json "$url" 2>/dev/null) || true
  if [ -n "$json_out" ]; then
    local content
    content=$(echo "$json_out" | jq -r '.content // empty' 2>/dev/null) || true
    if [ -n "$content" ] && [ "${#content}" -gt 200 ]; then
      echo "$content"
      rm -f "$tmpfile"
      return 0
    fi
  fi

  rm -f "$tmpfile"
  return 1
}

# Liteparse: download page HTML, parse as document
extract_web_liteparse() {
  local url="$1"
  if ! command -v liteparse &>/dev/null; then
    log "extract_web_liteparse: liteparse not found in PATH"
    return 1
  fi

  local tmpfile
  tmpfile=$(mktemp /tmp/liteparse-web-XXXXXX.html)

  # Download the page HTML
  if ! curl -sL --max-time 30 \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
    "$url" -o "$tmpfile" 2>/dev/null; then
    rm -f "$tmpfile"
    return 1
  fi

  # Parse with liteparse
  local content
  content=$(liteparse parse --format text "$tmpfile" 2>/dev/null | head -5000) || true
  if [ -n "$content" ]; then
    echo "$content"
    rm -f "$tmpfile"
    return 0
  fi

  rm -f "$tmpfile"
  return 1
}

# Tavily: web search API extraction
extract_web_tavily() {
  local url="$1"
  # Tavily extraction is MCP-based — return signal for caller to use MCP tools
  # This function is a placeholder; actual tavily calls happen in the agent loop
  log "extract_web_tavily: delegating to agent MCP tools for $url"
  return 1
}

# Browser screenshot: last resort for JS-heavy or blocked sites
extract_web_screenshot() {
  local url="$1"
  # Browser screenshot is MCP-based — return signal for caller
  log "extract_web_screenshot: delegating to agent browser tools for $url"
  return 1
}

# ═══════════════════════════════════════════════════════════
# DOCUMENT / FILE EXTRACTION (PDF, DOCX, PPTX, XLSX)
# ═══════════════════════════════════════════════════════════
# Chain: liteparse (local) → ocr-and-documents skill → browser render
#
# Usage: content=$(extract_document "/path/to/file.pdf")
# Returns: markdown content on stdout, exits 1 if all methods fail

extract_document() {
  local file="$1"
  local output=""
  local rc=1

  if [ ! -f "$file" ]; then
    log "extract_document: file not found: $file"
    return 1
  fi

  local ext="${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  log "extract_document: extracting $ext file: $file"

  # ── Tier 1: Liteparse (primary — local, fast, good quality) ──
  output=$(extract_document_liteparse "$file") && rc=0 || rc=$?
  if [ $rc -eq 0 ] && [ -n "$output" ] && [ "${#output}" -gt 100 ]; then
    log "extract_document: liteparse succeeded for $file (${#output} chars)"
    echo "$output"
    return 0
  fi
  log "extract_document: liteparse failed for $file, trying fallback..."

  # ── Tier 2: OCR and documents skill (for scanned/image PDFs) ──
  output=$(extract_document_ocr "$file") && rc=0 || rc=$?
  if [ $rc -eq 0 ] && [ -n "$output" ] && [ "${#output}" -gt 100 ]; then
    log "extract_document: OCR fallback succeeded for $file (${#output} chars)"
    echo "$output"
    return 0
  fi

  log "extract_document: ALL extraction methods failed for $file"
  return 1
}

# Liteparse: primary document parser
extract_document_liteparse() {
  local file="$1"
  if ! command -v liteparse &>/dev/null; then
    log "extract_document_liteparse: liteparse not found in PATH"
    return 1
  fi

  local tmpfile
  tmpfile=$(mktemp /tmp/liteparse-doc-XXXXXX.md)

  if liteparse parse --format text -o "$tmpfile" "$file" 2>/dev/null; then
    if [ -s "$tmpfile" ] && [ "$(wc -c < "$tmpfile")" -gt 100 ]; then
      cat "$tmpfile"
      rm -f "$tmpfile"
      return 0
    fi
  fi

  rm -f "$tmpfile"
  return 1
}

# OCR fallback: for scanned documents
extract_document_ocr() {
  local file="$1"
  local ext="${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  # For PDFs: try liteparse with OCR enabled
  if [ "$ext" = "pdf" ] && command -v liteparse &>/dev/null; then
    local tmpfile
    tmpfile=$(mktemp /tmp/liteparse-ocr-XXXXXX.md)

    if liteparse parse --format text --dpi 300 -o "$tmpfile" "$file" 2>/dev/null; then
      if [ -s "$tmpfile" ] && [ "$(wc -c < "$tmpfile")" -gt 100 ]; then
        cat "$tmpfile"
        rm -f "$tmpfile"
        return 0
      fi
    fi
    rm -f "$tmpfile"
  fi

  return 1
}

# ═══════════════════════════════════════════════════════════
# FILE TYPE DETECTION
# ═══════════════════════════════════════════════════════════

# Detect if a URL/path is a document file (PDF/DOCX/PPTX/XLSX)
# Returns: 0 if document, 1 if web/URL
is_document_file() {
  local input="$1"

  # Check file extension
  case "$input" in
    *.pdf|*.PDF) return 0 ;;
    *.docx|*.DOCX) return 0 ;;
    *.pptx|*.PPTX) return 0 ;;
    *.xlsx|*.XLSX) return 0 ;;
    *.doc|*.DOC) return 0 ;;
    *.ppt|*.PPT) return 0 ;;
    *.xls|*.XLS) return 0 ;;
  esac

  # Check if it's a local file with document MIME type
  if [ -f "$input" ]; then
    local mime
    mime=$(file -b --mime-type "$input" 2>/dev/null) || true
    case "$mime" in
      application/pdf) return 0 ;;
      application/vnd.openxmlformats-officedocument.*) return 0 ;;
      application/msword) return 0 ;;
      application/vnd.ms-*) return 0 ;;
    esac
  fi

  return 1
}

# Detect if a URL is X/Twitter
is_twitter_url() {
  local url="$1"
  case "$url" in
    https://x.com/*|http://x.com/*|https://*.x.com/*|http://*.x.com/*|https://twitter.com/*|http://twitter.com/*|https://*.twitter.com/*|http://*.twitter.com/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ═══════════════════════════════════════════════════════════
# UNIFIED EXTRACTION ENTRY POINT
# ═══════════════════════════════════════════════════════════
# Auto-detects type and routes to correct extraction chain.
#
# Usage: content=$(extract_content "$url_or_path")
# Returns: markdown content on stdout

extract_content() {
  local input="$1"

  if is_document_file "$input"; then
    extract_document "$input"
  else
    extract_web "$input"
  fi
}
