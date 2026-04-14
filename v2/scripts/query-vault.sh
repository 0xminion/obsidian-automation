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

query_count=$(find "$VAULT_PATH/03-Queries" -name '*.md' 2>/dev/null | wc -l)
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
    count=$(find "$dir_path" -name '*.md' 2>/dev/null | wc -l)
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
    edge_count=$(( $(wc -l < "$VAULT_PATH/06-Config/edges.tsv") - 1 ))
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
   Also check '06-Config/edges.tsv' for typed relationships between notes.

3. Read the FULL content of each relevant note — don't just rely on titles.

4. Synthesize a comprehensive answer from the wiki content.
   If the wiki content is insufficient, note what's missing and suggest
   what additional sources could fill the gap.

5. DISCOVER NEW CONCEPTS: If your research reveals important concepts not
   already in 04-Wiki/concepts/, CREATE new Concept notes for them.
   Before creating, check if an existing concept covers the same idea.
   If yes, UPDATE the existing concept instead.

6. CREATE AN ENTRY NOTE IN 04-Wiki/entries/ — this is how the answer
   becomes part of the wiki.

   Create the Entry following this EXACT structure:
   ---
   title: \"Answer: <query topic>\"
   source: \"[[$query_name]]\"
   date_entry: $(date +%Y-%m-%d)
   reviewed: null
   review_notes: null
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

7. COMPOUND-BACK: This is critical. After creating the answer Entry, review
   existing wiki pages for connections your research revealed:
   - If you found that Entry X contradicts Entry Y, update BOTH entries'
     'Open questions' or 'Linked concepts' sections to note the contradiction.
   - If you discovered that Concept A is related to Entry B, add a wikilink
     in Entry B's 'Linked concepts' and Concept A's 'References'.
   - If a new connection exists between two previously-unrelated notes,
     add typed edges to '06-Config/edges.tsv':
       NoteA<tab>NoteB<tab>type<tab>description
   - Do NOT just create a standalone answer — UPDATE the broader wiki.
   - Humanize all updated prose.

8. ALSO write a copy to '05-Outputs/answers/' as:
   answer-$(date +%Y%m%d)-${query_name}.md
   This is a duplicate for quick access — the canonical version is
   the Entry in 04-Wiki/entries/.

9. Humanize ALL prose using the Humanizer skill (Entry, output copy, and any updated notes).

10. LOG THE QUERY: Append a structured entry to '06-Config/log.md':
   ## [YYYY-MM-DD] query | \"<question>\"
   - Consulted: [[Entry1]], [[Concept1]], [[MoC Name]]
   - Created Entry: [[Answer: ...]]
   - New concepts: [[NewConcept1]] (if any)
   - Updated existing notes: [[Note1]], [[Note2]] (compound-back connections)
   - New edges: N (in edges.tsv)

11. Archive the query: move it from '03-Queries/' to '08-Archive-Raw/'.

CRITICAL RULES:
- ALL YAML frontmatter: wikilinks MUST be quoted: source: \"[[note]]\"
- Use [[wikilinks]] for all internal vault links.
- Do NOT modify 07-WIP/.
- The compound-back step (7) is MANDATORY — queries must improve the wiki.
"

  if run_with_retry "Query: $query_name" "$prompt"; then
    log "Query answered (v2.2): $query_name"
  else
    log "Query FAILED (v2.2): $query_name"
  fi
done

log "=== All queries processed (v2.2) ==="
auto_commit "query" "Processed $query_count queries"
echo "Done. Processed $query_count queries."
