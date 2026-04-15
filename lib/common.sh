#!/usr/bin/env bash
# ============================================================================
# v2.2: Common Library — Shared functions for all wiki scripts
# ============================================================================
# Source this file from any script: source "$(dirname "$0")/../lib/common.sh"
# Or: source "$SCRIPT_DIR/lib/common.sh"
#
# Provides: log(), run_with_retry(), lock management, directory setup,
#            url dedup helpers, logging to structured log.md
# ============================================================================

set -uo pipefail

# ═══════════════════════════════════════════════════════════
# CONFIGURATION (inherited from caller or defaults)
# ═══════════════════════════════════════════════════════════
VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
LOG_FILE="$VAULT_PATH/Meta/Scripts/processing.log"
AGENT_CMD="${AGENT_CMD:-claude -p}"
MAX_RETRIES="${MAX_RETRIES:-3}"

mkdir -p "$VAULT_PATH/Meta/Scripts"

# ═══════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

# Append a structured entry to log.md (Karpathy-style)
# Usage: append_log_md "ingest" "Article Title" "details bullet list"
append_log_md() {
  local operation="$1"
  local title="$2"
  local details="${3:-}"
  local log_md="$VAULT_PATH/06-Config/log.md"
  local date_str
  date_str=$(date +%Y-%m-%d)

  # Note: setup_directory_structure() already initializes log.md.
  # This fallback only triggers if called before setup (edge case).
  if [ ! -f "$log_md" ]; then
    mkdir -p "$(dirname "$log_md")"
    cat > "$log_md" << 'HEADER'
# Wiki Activity Log

Chronological record of all operations on the knowledge base.
Use `grep "^## \[" log.md | tail -N` to see the last N operations.

---

HEADER
  fi

  cat >> "$log_md" << ENTRY

## [$date_str] $operation | $title
$details
ENTRY
}

# ═══════════════════════════════════════════════════════════
# LOCK FILE MANAGEMENT
# ═══════════════════════════════════════════════════════════
# Usage: acquire_lock "process-inbox"
# Exits 0 if lock acquired, exits 1 if another instance running
_lock_dir=""

acquire_lock() {
  local script_name="$1"
  local vault_hash
# Portable hash: try md5sum (GNU), then md5 -q (macOS), then cksum (fallback)
vault_hash=$(echo "$VAULT_PATH" | { md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum; } | cut -c1-8)
  _lock_dir="/tmp/obsidian-${script_name}-${vault_hash}.lock"

  # Atomic lock via mkdir (mkdir is atomic on all POSIX systems)
  if ! mkdir "$_lock_dir" 2>/dev/null; then
    echo "$(date): Another $script_name instance is already running. Exiting." >> "$LOG_FILE"
    return 1
  fi
  trap 'release_lock' EXIT INT TERM HUP
  return 0
}

release_lock() {
  rmdir "$_lock_dir" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════
# RETRY LOGIC — exponential backoff, max N attempts
# ═══════════════════════════════════════════════════════════
RETRY_ADVICE="
RETRY CONTEXT: Previous attempt failed. Try alternatives:
- If Defuddle failed, fall back to LiteParse (lit parse <file> --format text).
- If PDF parsing failed, try lit with --no-ocr or different page ranges.
- If TranscriptAPI failed, try bare video ID instead of full URL.
- If a file operation failed, verify the target directory exists (create if needed).
- If rate-limited, use a simpler/shorter prompt.
- If note write failed, write to a temp location first, then mv.
Be resourceful. Find a way."

run_with_retry() {
  local description="$1"
  local prompt="$2"
  local attempt=1
  local delay=5

  while [ $attempt -le $MAX_RETRIES ]; do
    log "Attempt $attempt/$MAX_RETRIES: $description"

    local result=0
    cd "$VAULT_PATH" && $AGENT_CMD "$prompt" 2>> "$LOG_FILE" || result=$?

    if [ $result -eq 0 ]; then
      log "SUCCESS: $description"
      return 0
    fi

    log "FAILED (exit $result): $description — attempt $attempt/$MAX_RETRIES"

    if [ $attempt -lt $MAX_RETRIES ]; then
      log "Waiting ${delay}s before retry (exponential backoff)..."
      sleep $delay
      delay=$((delay * 2))
      # Append retry advice only once — keep original prompt clean
      if [ $attempt -eq 1 ]; then
        prompt="${prompt}${RETRY_ADVICE}"
      fi
    fi

    attempt=$((attempt + 1))
  done

  log "GIVING UP after $MAX_RETRIES attempts: $description"
  # Try to archive failed file if description contains a file path
  local file_arg
  file_arg=$(echo "$description" | sed -n 's/.*file: //p' || true)
  if [ -n "$file_arg" ] && [ -f "$file_arg" ]; then
    mkdir -p "$VAULT_PATH/08-Archive-Raw/failed"
    mv "$file_arg" "$VAULT_PATH/08-Archive-Raw/failed/" 2>/dev/null || true
    log "Moved failed file to failed archive: $file_arg"
  fi
  return 1
}

# ═══════════════════════════════════════════════════════════
# URL DEDUPLICATION
# ═══════════════════════════════════════════════════════════
URL_INDEX="$VAULT_PATH/06-Config/url-index.tsv"
mkdir -p "$(dirname "$URL_INDEX")"
touch "$URL_INDEX"

source_exists_for_url() {
  local url="$1"
  local normalized_url
  normalized_url=$(echo "$url" | sed 's|^https\?://||; s|/$||')
  if grep -qiF "$normalized_url" "$URL_INDEX" 2>/dev/null; then
    return 0
  fi
  return 1
}

register_url_source() {
  local url="$1"
  local source_path="$2"
  local normalized_url
  normalized_url=$(echo "$url" | sed 's|^https\?://||; s|/$||')
  if ! grep -qiF "$normalized_url" "$URL_INDEX" 2>/dev/null; then
    echo -e "${normalized_url}\t${source_path}" >> "$URL_INDEX"
  fi
}

# Build index from existing Source notes if empty
bootstrap_url_index() {
  if [ ! -s "$URL_INDEX" ]; then
    for dir in "$VAULT_PATH/01-Sources" "$VAULT_PATH/04-Wiki/sources"; do
      [ -d "$dir" ] || continue
      for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        local url
        url=$(grep -m1 'source_url:' "$f" 2>/dev/null | sed 's/.*source_url: *//; s/^"//; s/"$//' || true)
        if [ -n "$url" ]; then
          register_url_source "$url" "$f"
        fi
      done
    done
    log "Built URL index from existing sources ($(wc -l < "$URL_INDEX") entries)"
  fi
}

# ═══════════════════════════════════════════════════════════
# DIRECTORY SETUP
# ═══════════════════════════════════════════════════════════
setup_directory_structure() {
  mkdir -p "$VAULT_PATH/01-Raw"
  mkdir -p "$VAULT_PATH/02-Clippings"
  mkdir -p "$VAULT_PATH/03-Queries"
  mkdir -p "$VAULT_PATH/04-Wiki/entries"
  mkdir -p "$VAULT_PATH/04-Wiki/concepts"
  mkdir -p "$VAULT_PATH/04-Wiki/mocs"
  mkdir -p "$VAULT_PATH/04-Wiki/sources"
  mkdir -p "$VAULT_PATH/05-Outputs/answers"
  mkdir -p "$VAULT_PATH/05-Outputs/visualizations"
  mkdir -p "$VAULT_PATH/06-Config"
  mkdir -p "$VAULT_PATH/07-WIP"
  mkdir -p "$VAULT_PATH/08-Archive-Raw"
  mkdir -p "$VAULT_PATH/09-Archive-Queries"
  mkdir -p "$VAULT_PATH/Meta/Scripts"
  mkdir -p "$VAULT_PATH/Meta/Templates"

  # Initialize wiki-index.md if missing
  if [ ! -f "$VAULT_PATH/06-Config/wiki-index.md" ]; then
    cat > "$VAULT_PATH/06-Config/wiki-index.md" << 'HEADER'
# Wiki Index

Auto-maintained table of contents for the knowledge base.
Each entry and concept has a 1-sentence summary for retrieval.
This index is the primary retrieval layer — the LLM reads this
to find relevant notes instead of using RAG.

---

HEADER
  fi

  # Initialize log.md if missing
  if [ ! -f "$VAULT_PATH/06-Config/log.md" ]; then
    cat > "$VAULT_PATH/06-Config/log.md" << 'HEADER'
# Wiki Activity Log

Chronological record of all operations on the knowledge base.
Use `grep "^## \[" log.md | tail -N` to see the last N operations.

---

HEADER
  fi

  # Initialize tag-registry.md if missing
  if [ ! -f "$VAULT_PATH/06-Config/tag-registry.md" ]; then
    cat > "$VAULT_PATH/06-Config/tag-registry.md" << 'HEADER'
# Tag Registry

Canonical list of tags used in this wiki. Before minting a new tag,
check this registry and prefer reuse.

## Entry Tags


## Concept Tags

HEADER
  fi

  # Initialize edges.tsv if missing
  if [ ! -f "$VAULT_PATH/06-Config/edges.tsv" ]; then
    cat > "$VAULT_PATH/06-Config/edges.tsv" << 'HEADER'
source	target	type	description
HEADER
  fi
}

# ═══════════════════════════════════════════════════════════
# EDGES: Typed relationship management
# ═══════════════════════════════════════════════════════════
EDGES_FILE="$VAULT_PATH/06-Config/edges.tsv"

# Add an edge between two notes
# Usage: add_edge "Source Note" "Target Note" "contradicts" "why it contradicts"
add_edge() {
  local source="$1"
  local target="$2"
  local edge_type="$3"
  local description="${4:-}"
  local edges_file="$EDGES_FILE"
  mkdir -p "$(dirname "$edges_file")"
  touch "$edges_file"

  # Check for duplicate edge
  if grep -qF "${source}	${target}	${edge_type}" "$edges_file" 2>/dev/null; then
    return 0
  fi

  echo -e "${source}\t${target}\t${edge_type}\t${description}" >> "$edges_file"
}

# Get all edges for a note (both directions)
# Usage: get_edges "Note Name"
get_edges() {
  local note="$1"
  local edges_file="$EDGES_FILE"
  [ -f "$edges_file" ] || return
  # Exact match on source (col 1) or target (col 2) — avoids substring false positives
  awk -F'\t' -v n="$note" '$1 == n || $2 == n' "$edges_file" 2>/dev/null || true
}

# Get edges by type
# Usage: get_edges_by_type "contradicts"
get_edges_by_type() {
  local edge_type="$1"
  local edges_file="$EDGES_FILE"
  [ -f "$edges_file" ] || return
  awk -F'\t' -v et="$edge_type" '$3 == et' "$edges_file" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════
# PROMPT LOADING
# ═══════════════════════════════════════════════════════════
# Load a prompt template from prompts/
# Usage: prompt=$(load_prompt "entry-structure")
# Returns the file content, or empty string if not found.
PROMPT_DIR_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../prompts" 2>/dev/null && pwd || echo "")"

load_prompt() {
  local name="$1"
  local prompt_dir="${2:-$PROMPT_DIR_DEFAULT}"
  local prompt_file="$prompt_dir/${name}.prompt"

  if [ -f "$prompt_file" ]; then
    cat "$prompt_file"
  else
    log "WARNING: Prompt file not found: $prompt_file"
    echo ""
  fi
}

# ═══════════════════════════════════════════════════════════
# GIT SAFETY: Auto-commit helper
# ═══════════════════════════════════════════════════════════
auto_commit() {
  local operation="$1"
  local message="$2"
  local vault_dir="$VAULT_PATH"

  # Only commit if vault is a git repo
  if [ ! -d "$vault_dir/.git" ]; then
    return 0
  fi

  cd "$vault_dir"
  git add -A 2>/dev/null || true

  # Only commit if there are changes
  if ! git diff --cached --quiet 2>/dev/null; then
    local date_str
    date_str=$(date +%Y-%m-%d)
    git commit -m "$operation: $message ($date_str)" --quiet 2>/dev/null || true
    log "Git commit: $operation: $message"
  fi
}
