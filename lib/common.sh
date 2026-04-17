#!/usr/bin/env bash
# ============================================================================
# v2.1.0: Common Library — Shared functions for all wiki scripts
# ============================================================================
# Source this file from any script: source "$(dirname "$0")/../lib/common.sh"
# Or: source "$SCRIPT_DIR/lib/common.sh"
#
# Provides: log(), run_with_retry(), lock management, directory setup,
#            url dedup helpers, logging to structured log.md
# ============================================================================

set -uo pipefail

# C2 fix: guard against double-sourcing
if [ -n "${_COMMON_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_COMMON_SH_LOADED=1

# ═══════════════════════════════════════════════════════════
# LOAD .env FILE (secrets, API keys)
# ═══════════════════════════════════════════════════════════
# Looks for .env in script dir, then repo root
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
for _env_candidate in "$SCRIPT_DIR/.env" "$(dirname "$SCRIPT_DIR")/.env"; do
  if [ -f "$_env_candidate" ]; then
    set -a
    source "$_env_candidate"
    set +a
    break
  fi
done
unset _env_candidate

# ═══════════════════════════════════════════════════════════
# CONFIGURATION (inherited from caller or defaults)
# ═══════════════════════════════════════════════════════════
VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
LOG_FILE="$VAULT_PATH/Meta/Scripts/processing.log"
AGENT_CMD="${AGENT_CMD:-hermes}"
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

  # Check for stale lock (process that created it is no longer running, or too old)
  if [ -d "$_lock_dir" ]; then
    local lock_pid_file="$_lock_dir/pid"
    
    # Time-based stale detection: if lock dir older than 30 minutes, force remove
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -c %Y "$_lock_dir" 2>/dev/null || stat -f %m "$_lock_dir" 2>/dev/null || echo 0) ))
    if [ "$lock_age" -gt 1800 ]; then
      echo "$(date): Removing stale lock for $script_name (${lock_age}s old, exceeding 30min threshold)" >> "$LOG_FILE"
      rm -rf "$_lock_dir" 2>/dev/null || true
    elif [ -f "$lock_pid_file" ]; then
      local lock_pid
      lock_pid=$(cat "$lock_pid_file" 2>/dev/null)
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        echo "$(date): Removing stale lock for $script_name (PID $lock_pid no longer running)" >> "$LOG_FILE"
        rm -rf "$_lock_dir" 2>/dev/null || true
      fi
    else
      # No PID file — legacy lock or very old instance, remove it
      echo "$(date): Removing stale lock for $script_name (no PID file)" >> "$LOG_FILE"
      rm -rf "$_lock_dir" 2>/dev/null || true
    fi
  fi

  # Atomic lock via mkdir (mkdir is atomic on all POSIX systems)
  if ! mkdir "$_lock_dir" 2>/dev/null; then
    echo "$(date): Another $script_name instance is already running. Exiting." >> "$LOG_FILE"
    return 1
  fi

  # Store PID for stale lock detection
  echo $$ > "$_lock_dir/pid" 2>/dev/null || true

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
    # Timeout agent calls at 10 minutes to prevent hangs on long prompts
    # Use heredoc to safely pass prompt — prevents shell injection from prompt content
    cd "$VAULT_PATH" && timeout 600 bash -c '"$AGENT_CMD" chat' <<< "$prompt" 2>> "$LOG_FILE" || result=$?

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
    for dir in "$VAULT_PATH/01-Raw" "$VAULT_PATH/04-Wiki/sources"; do
      [ -d "$dir" ] || continue
      for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        local url
        url=$(grep -m1 'source_url:' "$f" 2>/dev/null | sed 's/.*source_url: *//; s/^\"//; s/\"$//' || true)
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
# FILENAME COLLISION DETECTION
# ═══════════════════════════════════════════════════════════
# Check if writing a note would overwrite an existing file.
# Usage: check_collision "entries" "My-Note-Title" || echo "collision!"
# Returns: 0 if safe, 1 if file already exists
check_collision() {
  local note_dir="$1"
  local note_name="$2"
  local target="$VAULT_PATH/04-Wiki/$note_dir/${note_name}.md"
  [ ! -f "$target" ]
}

# Generate a unique filename by appending a suffix if collision detected.
# Usage: unique_name=$(resolve_collision "entries" "My-Note-Title")
resolve_collision() {
  local note_dir="$1"
  local note_name="$2"
  local counter=1
  local candidate="$note_name"

  while ! check_collision "$note_dir" "$candidate"; do
    candidate="${note_name}-${counter}"
    counter=$((counter + 1))
    [ $counter -gt 100 ] && { echo "${note_name}-$(date +%s)"; return; }
  done
  echo "$candidate"
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

# ═══════════════════════════════════════════════════════════
# TITLE CLEANING — Generate human-readable filenames from content
# ═══════════════════════════════════════════════════════════
# Takes raw content + URL and produces a clean kebab-case title.
# Falls back to URL slug if no title found in content.
#
# Usage: title=$(clean_title "$content" "$url")

clean_title() {
  local content="$1"
  local url="$2"
  local title=""

  # Extract title from content (first # heading, or first line with substantial text)
  # Try markdown H1 first
  title=$(echo "$content" | grep -m1 '^# ' | sed 's/^# //' | head -1)
  
  # If empty, try first bold text
  if [ -z "$title" ]; then
    # Try GNU grep -P first, fall back to POSIX grep -E
    title=$(echo "$content" | grep -m1P '\*\*[^*]+\*\*' 2>/dev/null | sed 's/.*\*\*//;s/\*\*.*//' | head -1)
    if [ -z "$title" ]; then
      title=$(echo "$content" | grep -m1E '\*\*[^*]+\*\*' 2>/dev/null | sed 's/.*\*\*//;s/\*\*.*//' | head -1)
    fi
  fi

  # If still empty, try first non-empty line that's > 20 chars
  if [ -z "$title" ]; then
    title=$(echo "$content" | grep -m1 '^.\{20,\}' | head -1)
  fi

  # Clean the title
  if [ -n "$title" ]; then
    # Remove common prefixes/suffixes
    title=$(echo "$title" | sed \
      -e 's/^danny on X: "//' \
      -e 's/^.*on X: "//' \
      -e 's/" \/\/ X$//' \
      -e 's/ | by .*$//' \
      -e 's/ | Medium$//' \
      -e 's/\s*—.*$//' \
      -e 's/^[[:space:]]*//' \
      -e 's/[[:space:]]*$//')
    
    # Truncate to reasonable length
    title=$(echo "$title" | head -c 120)
    echo "$title"
    return 0
  fi

  # Fallback: derive from URL
  # e.g. https://blog.example.com/great-article → great-article
  # NEVER use tweet IDs or pure numeric slugs
  if echo "$url" | grep -qE 'x\.com|twitter\.com'; then
    # For X/Twitter, return empty — force caller to extract content title
    echo ""
    return 1
  fi
  
  title=$(echo "$url" | sed \
    -e 's|https\?://||' \
    -e 's|www\.||' \
    -e 's|arxiv\.org/abs/|arxiv-|' \
    -e 's|/.*$||' \
    -e 's|[?#].*$||' \
    -e 's|\.[a-z]*$||')
  
  # Reject pure numeric slugs (tweet IDs, short codes)
  if echo "$title" | grep -qE '^[0-9]+$'; then
    echo ""
    return 1
  fi
  
  echo "$title"
}

# ═══════════════════════════════════════════════════════════
# FILENAME FROM TITLE — Generate safe filename from title
# ═══════════════════════════════════════════════════════════
# Rules:
#   - Chinese titles → use Chinese as filename (keep original chars)
#   - English titles → kebab-case lowercase
#   - Papers → use actual paper title, not arxiv/DOI ID
#   - Truncate to 120 chars for filesystem safety
#   - Strip: quotes, colons (replace with -), special chars
#
# Usage: filename=$(title_to_filename "$title")

title_to_filename() {
  local title="$1"
  local has_chinese
  
  # Check if title contains Chinese characters
  has_chinese=$(echo "$title" | grep -cP '[\x{4e00}-\x{9fff}]' 2>/dev/null || echo "$title" | grep -c '[一-龥]' || echo "0")
  
  if [ "$has_chinese" -gt 0 ]; then
    # Chinese title: keep Chinese chars, replace specials
    echo "$title" | sed \
      -e 's/[：:]/-/g' \
      -e 's/[？?！!，,。.、]/ /g' \
      -e 's/[\"'"'"'《》「」（）\(\)]//g' \
      -e 's/[[:space:]]*$//' \
      -e 's/^[[:space:]]*//' \
      | head -c 120
  else
    # English title: kebab-case
    echo "$title" | tr '[:upper:]' '[:lower:]' \
      | sed -e "s/[''']//g" \
      -e 's/[^a-zA-Z0-9]/-/g' \
      -e 's/--*/-/g' \
      -e 's/^-//' \
      -e 's/-$//' \
      | head -c 120
  fi
}

# ═══════════════════════════════════════════════════════════
# QMD INTEGRATION — Semantic concept search via qmd
# ═══════════════════════════════════════════════════════════
# Uses qmd (https://github.com/tobi/qmd) with Qwen3-Embedding-0.6B-Q8
# for semantic concept matching instead of keyword grep.
#
# Prerequisites:
#   1. npm install -g @tobilu/qmd
#   2. qmd collection add <vault>/04-Wiki/concepts --name concepts
#   3. qmd embed
#   See scripts/setup-qmd.sh for automated setup.
#
# Environment:
#   QMD_EMBED_MODEL  — Override embedding model (default: Qwen3-Embedding-0.6B-Q8)
#   QMD_CMD          — Path to qmd binary (default: auto-detect from PATH)

QMD_CMD="${QMD_CMD:-$(command -v qmd 2>/dev/null || echo "")}"
QMD_COLLECTION="${QMD_COLLECTION:-concepts}"
QMD_EMBED_MODEL="${QMD_EMBED_MODEL:-hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf}"
export QMD_CMD QMD_COLLECTION QMD_EMBED_MODEL

# Check if qmd is available and concepts collection is indexed
qmd_available() {
  [ -n "$QMD_CMD" ] && [ -x "$QMD_CMD" ] || return 1
  # Use temp file to avoid pipefail interaction with qmd's non-zero exit (Vulkan warnings)
  local status_out
  status_out=$(timeout 30 "$QMD_CMD" status 2>/dev/null) || true
  echo "$status_out" | grep -q "$QMD_COLLECTION"
}

# Semantic concept search via qmd query
# Usage: results_json=$(qmd_concept_search "source content preview" 8 0.3)
# Returns: JSON array of {score, file, title} objects
# Falls back to empty array if qmd unavailable or errors
qmd_concept_search() {
  local query_text="$1"
  local max_results="${2:-8}"
  local min_score="${3:-0.3}"

  if ! qmd_available; then
    log "WARN: qmd not available, returning empty concept matches"
    echo "[]"
    return 1
  fi

  # Run qmd query — suppress Vulkan build warnings (node-llama-cpp noise)
  # NOTE: cmake/Vulkan warnings go to stdout (not stderr), so we strip them
  # Use printf to prevent shell expansion of special chars in query_text
  local result
  result=$(printf '%s' "$query_text" | xargs -0 "$QMD_CMD" query \
    --json -n "$max_results" --min-score "$min_score" \
    -c "$QMD_COLLECTION" --no-rerank \
    2>/dev/null) || {
    log "WARN: qmd query failed for: ${query_text:0:80}"
    echo "[]"
    return 1
  }

  # Strip cmake/node-llama-cpp noise from stdout
  # cmake/Vulkan warnings contain '[' chars — find actual JSON array start
  # JSON results always start with '[\n  {\n    "docid"' pattern
  result=$(echo "$result" | python3 -c "
import sys, json
text = sys.stdin.read()
# Find the JSON array: look for pattern '[\n  {\n' or '[\n{\n'
for marker in ['[\n  {', '[\n{']:
    idx = text.find(marker)
    if idx >= 0:
        try:
            parsed = json.loads(text[idx:].rstrip())
            print(json.dumps(parsed))
            sys.exit(0)
        except json.JSONDecodeError:
            continue
# Fallback: try parsing entire output
try:
    parsed = json.loads(text.strip())
    print(json.dumps(parsed))
except Exception:
    print('[]')
" 2>/dev/null) || { echo "[]"; return 1; }

  # Validate output is valid JSON array
  if echo "$result" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    echo "$result"
  else
    log "WARN: qmd returned non-JSON output"
    echo "[]"
    return 1
  fi
}

# Extract concept names from qmd results
# Usage: concept_names=$(qmd_results_to_names "$qmd_json")
# Returns: JSON array of concept name strings, e.g. ["prediction-markets","forecasting"]
qmd_results_to_names() {
  local qmd_json="$1"
  echo "$qmd_json" | python3 -c "
import json, sys
try:
    results = json.load(sys.stdin)
    names = []
    for r in results:
        # qmd returns file paths like 'qmd://concepts/prediction-markets.md'
        f = r.get('file', '')
        # Extract concept name from path (basename without extension)
        name = f.split('/')[-1].replace('.md', '') if '/' in f else f.replace('.md', '')
        if name and name not in names:
            names.append(name)
    print(json.dumps(names))
except Exception:
    print('[]')
" 2>/dev/null || echo "[]"
}

# Batch concept search: search all sources against concepts collection
# Usage: matches_json=$(qmd_batch_concept_search "$manifest_json")
# Input: JSON array of {hash, title, content} objects
# Output: JSON object {hash: [concept_names]} — same format as old Python matcher
qmd_batch_concept_search() {
  local manifest_json="$1"

  if ! qmd_available; then
    log "WARN: qmd unavailable, returning empty matches for all sources"
    echo "$manifest_json" | python3 -c "
import json, sys
manifest = json.load(sys.stdin)
print(json.dumps({e['hash']: [] for e in manifest}))
"
    return 1
  fi

  echo "$manifest_json" | python3 -c "
import json, sys, subprocess, os

manifest = json.load(sys.stdin)
qmd_cmd = os.environ.get('QMD_CMD', 'qmd')
collection = os.environ.get('QMD_COLLECTION', 'concepts')

matches = {}
for entry in manifest:
    h = entry['hash']
    # Build search query from title + content preview (first 500 chars)
    title = entry.get('title', '')
    content = entry.get('content', '')[:500]
    query = f'{title} {content}'.strip()[:800]

    if not query:
        matches[h] = []
        continue

    try:
        result = subprocess.run(
            [qmd_cmd, 'query', query, '--json', '-n', '8', '--min-score', '0.3',
             '-c', collection, '--no-rerank'],
            capture_output=True, text=True, timeout=300
        )
        # Strip cmake/Vulkan noise from stdout — find actual JSON array start
        stdout_clean = result.stdout
        for marker in ['[\n  {', '[\n{']:
            idx = stdout_clean.find(marker)
            if idx >= 0:
                try:
                    json.loads(stdout_clean[idx:].rstrip())
                    stdout_clean = stdout_clean[idx:].rstrip()
                    break
                except json.JSONDecodeError:
                    continue
        else:
            # Fallback: try parsing entire output as-is
            try:
                json.loads(stdout_clean.strip())
                stdout_clean = stdout_clean.strip()
            except Exception:
                stdout_clean = '[]'

        if result.returncode == 0 and stdout_clean.startswith('['):
            qmd_results = json.loads(stdout_clean)
            names = []
            for r in qmd_results:
                f = r.get('file', '')
                name = f.split('/')[-1].replace('.md', '') if '/' in f else f.replace('.md', '')
                if name and name not in names:
                    names.append(name)
            matches[h] = names[:8]
        else:
            matches[h] = []
    except Exception:
        matches[h] = []

print(json.dumps(matches))
" 2>/dev/null || echo "{}"
}
