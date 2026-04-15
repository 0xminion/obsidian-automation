#!/usr/bin/env bash
# ============================================================================
# v2.2: Query Vault — Q&A against the wiki knowledge base (Karpathy-style)
# ============================================================================
# Changes from v2.1:
#   - Sources common library (lib/common.sh)
#   - Query-compound-back: after creating answer Entry, LLM also updates
#     existing wiki pages with newly-discovered connections
#   - Git auto-commit after queries
#
# Usage: VAULT_PATH="$HOME/MyVault" bash query-vault.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

setup_directory_structure

mkdir -p "$VAULT_PATH/03-Queries"
mkdir -p "$VAULT_PATH/05-Outputs/answers"
mkdir -p "$VAULT_PATH/08-Archive-Raw"
mkdir -p "$VAULT_PATH/04-Wiki/concepts"

query_count=$(find "$VAULT_PATH/03-Queries" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
if [ "$query_count" -eq 0 ]; then
  echo "No query files found in $VAULT_PATH/03-Queries/"
  echo "Create a .md file with your question and re-run."
  log "Query (v2.2): No queries found"
  exit 0
fi

log "=== Starting query processing (v2.2) ==="

# Build vault summary from wiki-index.md (fast retrieval layer)
build_vault_summary() {
  echo "VAULT STRUCTURE OVERVIEW (v2.2):"
  echo ""

  if [ -f "$VAULT_PATH/06-Config/wiki-index.md" ]; then
    echo "## Wiki Index (primary retrieval):"
    cat "$VAULT_PATH/06-Config/wiki-index.md"
    echo ""
  fi

  # Also provide directory counts
  for dir in "04-Wiki/entries" "04-Wiki/concepts" "04-Wiki/mocs" "04-Wiki/sources"; do
    dir_path="$VAULT_PATH/$dir"
    [ -d "$dir_path" ] || continue
    count=$(find "$dir_path" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    echo "## $dir/ ($count notes):"
    if [ "$count" -gt 0 ] && [ "$count" -le 20 ]; then
      for note in "$dir_path"/*.md; do
        [ -f "$note" ] || continue
        note_name=$(basename "$note" .md)
        heading=$(grep -m1 '^# ' "$note" 2>/dev/null | sed 's/^# //' || echo "<no heading>")
        echo "  - [[$note_name]]: $heading"
      done
    elif [ "$count" -gt 20 ]; then
      echo "  ($count notes — too many to list, use wiki-index.md)"
    fi
    echo ""
  done

  # Include typed edges summary
  if [ -f "$VAULT_PATH/06-Config/edges.tsv" ]; then
    local edge_count
    edge_count=$(( $(wc -l < "$VAULT_PATH/06-Config/edges.tsv" | tr -d ' ') - 1 ))
    if [ "$edge_count" -gt 0 ]; then
      echo "## Typed Edges ($edge_count relationships):"
      head -20 "$VAULT_PATH/06-Config/edges.tsv"
      echo ""
    fi
  fi
}

VAULT_SUMMARY=$(build_vault_summary)

for query_file in "$VAULT_PATH/03-Queries"/*.md; do
  [ -f "$query_file" ] || continue
  query_text=$(cat "$query_file")
  query_name=$(basename "$query_file" .md)
  log "Processing query: $query_name"

  # Load externalized prompt and substitute placeholders
  QUERY_PROMPT=$(load_prompt "query-vault")
  DATE_STAMP=$(date +%Y%m%d)
  TODAY=$(date +%Y-%m-%d)
  QUERY_PROMPT=$(echo "$QUERY_PROMPT" | sed \
    -e "s|{VAULT_PATH}|$VAULT_PATH|g" \
    -e "s|{VAULT_SUMMARY}|$VAULT_SUMMARY|g" \
    -e "s|{QUERY_TEXT}|$query_text|g" \
    -e "s|{QUERY_NAME}|$query_name|g" \
    -e "s|{DATE_STAMP}|$DATE_STAMP|g" \
    -e "s|{TODAY}|$TODAY|g")

  if run_with_retry "Query: $query_name" "$QUERY_PROMPT"; then
    log "Query answered (v2.2): $query_name"
  else
    log "Query FAILED (v2.2): $query_name"
  fi
done

log "=== All queries processed (v2.2) ==="
auto_commit "query" "Processed $query_count queries"
echo "Done. Processed $query_count queries."
