#!/usr/bin/env bash
# ============================================================================
# v2: Query Vault — Q&A against the wiki knowledge base (Karpathy-style)
# ============================================================================
# Drop a question file in queries/, run this script, get an answer.
# The query file should contain a single question or topic.
#
# KEY FEATURES:
# - Queries expand the wiki: answers filed as Entries in outputs/answers/
# - New concepts discovered during Q&A are added to 04-Wiki/concepts/
# - wiki-index.md serves as the retrieval layer (read it first)
# - Answered queries archived to 08-Archive-Raw/
#
# Usage: VAULT_PATH="$HOME/MyVault" bash v2/scripts/query-vault.sh
# ============================================================================

set -uo pipefail

VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
LOG_FILE="$VAULT_PATH/Meta/Scripts/processing.log"
AGENT_CMD="${AGENT_CMD:-claude -p}"

mkdir -p "$VAULT_PATH/Meta/Scripts"

log() { echo "$(date): $1" >> "$LOG_FILE"; }

# Retry with exponential backoff
MAX_RETRIES=3

RETRY_ADVICE="
RETRY CONTEXT: Previous attempt failed. Try alternatives:
- If search failed, try simpler or different keywords.
- If file write failed, write to /tmp first, then mv.
- If rate-limited, simplify the prompt.
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
      log "Waiting ${delay}s before retry..."
      sleep $delay
      delay=$((delay * 2))
      prompt="${prompt}${RETRY_ADVICE}"
    fi

    attempt=$((attempt + 1))
  done

  log "GIVING UP after $MAX_RETRIES attempts: $description"
  return 1
}

# Build vault summary from wiki-index.md (fast retrieval layer)
build_vault_summary() {
  echo "VAULT STRUCTURE OVERVIEW (v2):"
  echo ""

  # If wiki-index.md exists, use it as the retrieval layer
  if [ -f "$VAULT_PATH/06-Config/wiki-index.md" ]; then
    echo "## Wiki Index (primary retrieval):"
    cat "$VAULT_PATH/06-Config/wiki-index.md"
    echo ""
  fi

  # Also provide directory counts for context
  for dir in "04-Wiki/entries" "04-Wiki/concepts" "04-Wiki/mocs" "04-Wiki/sources"; do
    dir_path="$VAULT_PATH/$dir"
    [ -d "$dir_path" ] || continue

    count=$(find "$dir_path" -name '*.md' 2>/dev/null | wc -l)
    echo "## $dir/ ($count notes):"

    if [ "$count" -gt 0 ]; then
      for note in "$dir_path"/*.md; do
        [ -f "$note" ] || continue
        note_name=$(basename "$note" .md)
        heading=$(grep -m1 '^# ' "$note" 2>/dev/null | sed 's/^# //' || echo "<no heading>")
        tags=$(grep -A10 '^tags:' "$note" 2>/dev/null | grep '^ *-' | head -5 | sed 's/^ *- *//' | tr '\n' ', ' || true)
        echo "  - [[$note_name]]: $heading"
        [ -n "$tags" ] && echo "    Tags: $tags"
      done
    fi
    echo ""
  done
}

# Setup required directories
mkdir -p "$VAULT_PATH/queries"
mkdir -p "$VAULT_PATH/outputs/answers"
mkdir -p "$VAULT_PATH/08-Archive-Raw"
mkdir -p "$VAULT_PATH/04-Wiki/concepts"

query_count=$(find "$VAULT_PATH/queries" -name '*.md' 2>/dev/null | wc -l)
if [ "$query_count" -eq 0 ]; then
  echo "No query files found in $VAULT_PATH/queries/"
  echo "Create a .md file with your question and re-run."
  log "Query (v2): No queries found"
  exit 0
fi

log "=== Starting query processing (v2) ==="

# Build vault summary once (uses wiki-index.md for fast retrieval)
VAULT_SUMMARY=$(build_vault_summary)

for query_file in "$VAULT_PATH/queries"/*.md; do
  [ -f "$query_file" ] || continue
  query_text=$(cat "$query_file")
  query_name=$(basename "$query_file" .md)
  log "Processing query: $query_name"

  prompt="
VAULT LOCATION: $VAULT_PATH

$VAULT_SUMMARY

TASK: Answer a question against the wiki knowledge base.
Your answers should EXPAND the wiki, not just answer the question.

QUERY: $query_text

INSTRUCTIONS:

1. READ THE WIKI INDEX first: consult '06-Config/wiki-index.md' for an overview
   of all Entry and Concept notes in the wiki. This is your retrieval layer.

2. Use 'obsidian search <keywords>' to find relevant notes in the vault.
   Focus on 04-Wiki/entries/, 04-Wiki/concepts/, and 04-Wiki/mocs/.

3. Read the FULL content of each relevant note — don't just rely on titles.

4. Synthesize a comprehensive answer from the wiki content.
   If the wiki content is insufficient, note what's missing and suggest
   what additional sources could fill the gap.

5. DISCOVER NEW CONCEPTS: If your research reveals important concepts not
   already in 04-Wiki/concepts/, CREATE new Concept notes for them.
   Follow this structure:
   ---
   title: \"<concept name>\"
   date_created: $(date +%Y-%m-%d)
   updated: $(date +%Y-%m-%d)
   tags:
     - concept
     - relevant-tag-1
     - relevant-tag-2
   entry_refs:
     - \"[[Relevant Entry]]\"
   status: seed
   aliases: []
   ---

   # Concept Name

   <2-5 sentences explaining the idea.>

   ## References
   - Entries: [[Entry1]]
   - Related Concepts: [[Concept1]], [[Concept2]]

   Before creating, check if an existing concept covers the same idea.
   If yes, UPDATE the existing concept instead.

6. CREATE AN ENTRY NOTE IN 04-Wiki/entries/ — this is how the answer
   becomes part of the wiki. The answer IS a wiki entry that can be
   found by future queries and compile passes.

   Create the Entry in '04-Wiki/entries/' following this EXACT structure:
   ---
   title: \\\"Answer: <query topic>\\\"
   source: \\\"[[$query_name]]\\\"
   date_entry: $(date +%Y-%m-%d)
   tags:
     - entry
     - topic-tag-1
   status: review
   aliases: []
   ---

   # Answer: <query topic>

   ## Summary
   <1-2 sentence summary of what this answer covers.>

   ## ELI5 insights

   ### Core insights
   <Key findings from the wiki, explained in simple language.>

   ### Other takeaways
   <Additional findings.>

   ## Diagrams
   <Mermaid diagrams if applicable, or 'N/A — content is straightforward.'>

   ## Open questions
   <What the wiki doesn't cover. What would fill the gaps?>

   ## Linked concepts
   <Wikilinks to all Entry and Concept notes consulted.>

7. ALSO write a copy to 'outputs/answers/' as:
   answer-$(date +%Y%m%d)-${query_name}.md
   This is a duplicate for quick access — the canonical version is
   the Entry in 04-Wiki/entries/.

8. Humanize ALL prose using the Humanizer skill (both Entry and output copy).

9. Archive the query: move it from 'queries/' to '08-Archive-Raw/'.

CRITICAL RULES:
- ALL YAML frontmatter: wikilinks MUST be quoted: source: \"[[note]]\"
- Use [[wikilinks]] for all internal vault links.
- Do NOT modify 07-WIP/.
"

  if run_with_retry "Query: $query_name" "$prompt"; then
    log "Query answered (v2): $query_name"
  else
    log "Query FAILED (v2): $query_name"
  fi
done

log "=== All queries processed (v2) ==="
