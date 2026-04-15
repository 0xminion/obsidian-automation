#!/usr/bin/env bash
# ============================================================================
# Query Vault — Q&A against the knowledge base
# ============================================================================
# Inspired by Karpathy's Q&A concept. Drop a question file in
# 00-Inbox/queries/, run this script, get an answer note in 05-WIP/.
#
# The query file should contain a single question or topic:
#   "What are the key differences between gradient descent variants?"
#
# Usage: VAULT_PATH="$HOME/MyVault" bash scripts/query-vault.sh
# ============================================================================

set -uo pipefail

VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
LOG_FILE="$VAULT_PATH/Meta/Scripts/processing.log"
AGENT_CMD="${AGENT_CMD:-claude -p}"

log() { echo "$(date): $1" >> "$LOG_FILE"; }

# Build vault summary (table of contents for the agent)
build_vault_summary() {
  echo "VAULT STRUCTURE OVERVIEW:"
  echo ""

  for dir in "01-Sources" "02-Distilled" "03-Atomic" "04-MoCs"; do
    dir_path="$VAULT_PATH/$dir"
    [ -d "$dir_path" ] || continue

    count=$(find "$dir_path" -name '*.md' 2>/dev/null | wc -l)
    echo "## $dir/ ($count notes):"

    if [ "$count" -gt 0 ]; then
      for note in "$dir_path"/*.md; do
        [ -f "$note" ] || continue
        note_name=$(basename "$note" .md)
        # First line after frontmatter (heading)
        heading=$(grep -m1 '^# ' "$note" 2>/dev/null | sed 's/^# //' || echo "<no heading>")
        echo "  - [[$note_name]]: $heading"
      done
    fi
    echo ""
  done
}

# Process all query files
query_dir="$VAULT_PATH/00-Inbox/queries"
if [ ! -d "$query_dir" ]; then
  mkdir -p "$query_dir"
  log "Created queries directory: $query_dir"
fi

query_count=$(find "$query_dir" -name '*.md' 2>/dev/null | wc -l)
if [ "$query_count" -eq 0 ]; then
  echo "No query files found in $query_dir"
  echo "Create a .md file with your question and re-run."
  log "Query: No queries found"
  exit 0
fi

# Build vault summary once
VAULT_SUMMARY=$(build_vault_summary)

for query_file in "$query_dir"/*.md; do
  [ -f "$query_file" ] || continue
  query_text=$(cat "$query_file")
  query_name=$(basename "$query_file" .md)
  log "Processing query: $query_name"

  prompt="
VAULT LOCATION: $VAULT_PATH

$VAULT_SUMMARY

TASK: Answer a question against the vault knowledge base.

QUERY: $query_text

INSTRUCTIONS:
1. Use 'obsidian search <keywords>' to find relevant notes in the vault.
2. Read the full content of each relevant note.
3. Synthesize a comprehensive answer from the vault content.
4. If the vault content is insufficient, note what's missing and what
   additional sources could fill the gap.
5. Output the answer as a markdown file in '05-WIP/':
   - Filename: query-$(date +%Y%m%d)-${query_name}.md
   - Format:
     ---
     title: \"Answer: <query summary>\"
     date_answered: $(date +%Y-%m-%d)
     source_query: \"[[$query_name]]\"
     type: answer
     ---

     # Answer: <query summary>

     <Answer synthesized from vault notes, with wikilinks to all source
     notes referenced.>

     ## Sources Consulted
     - [[<note1>]]
     - [[<note2>]]

     ## Gaps
     <What the vault doesn't cover on this topic.>
6. Humanize all prose using the Humanizer skill.
7. Archive the query file: move it from '00-Inbox/queries/' to
   '06-Archive/processed-queries/'
"

  if cd "$VAULT_PATH" && $AGENT_CMD "$prompt" 2>> "$LOG_FILE"; then
    log "Query answered: $query_name"
  else
    log "Query failed: $query_name"
  fi
done

log "All queries processed."
