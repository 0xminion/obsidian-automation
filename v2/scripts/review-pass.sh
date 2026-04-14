#!/usr/bin/env bash
# ============================================================================
# v2.2: Review Pass — Interactive review of processed wiki entries
# ============================================================================
# Lets you discuss processed entries with the LLM, provide feedback,
# and enrich/update entries based on your domain expertise.
#
# Usage:
#   bash review-pass.sh --last 10          # Review last 10 entries
#   bash review-pass.sh --untouched        # Review entries never reviewed
#   bash review-pass.sh --topic "scaling"  # Review entries with this tag/topic
#   bash review-pass.sh --entry "Entry Name"  # Review a specific entry
#   bash review-pass.sh --interactive       # One-at-a-time with pauses for feedback
#
# The --interactive flag pauses after each entry summary for your input.
# Without it, entries are flagged for batch review (non-blocking).
# ============================================================================

set -uo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ═══════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════
MODE="untouched"
LIMIT=10
TOPIC=""
SPECIFIC_ENTRY=""
INTERACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)       MODE="last"; LIMIT="${2:-10}"; shift 2 ;;
    --untouched)  MODE="untouched"; shift ;;
    --topic)      MODE="topic"; TOPIC="${2}"; shift 2 ;;
    --entry)      MODE="entry"; SPECIFIC_ENTRY="${2}"; shift 2 ;;
    --interactive) INTERACTIVE=true; shift ;;
    --limit)      LIMIT="${2}"; shift 2 ;;
    -h|--help)
      echo "Usage: review-pass.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --last N          Review last N entries (default: 10)"
      echo "  --untouched       Review entries with reviewed: null"
      echo "  --topic TAG       Review entries matching this tag/topic"
      echo "  --entry NAME      Review a specific entry by name"
      echo "  --interactive     Pause for human feedback after each entry"
      echo "  --limit N         Max entries to review (default: 10)"
      echo ""
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ═══════════════════════════════════════════════════════════
# ENTRY SELECTION
# ═══════════════════════════════════════════════════════════
ENTRIES_DIR="$VAULT_PATH/04-Wiki/entries"

select_entries() {
  case "$MODE" in
    untouched)
      # Find entries where reviewed: is null or missing
      for entry in "$ENTRIES_DIR"/*.md; do
        [ -f "$entry" ] || continue
        local reviewed
        reviewed=$(grep -m1 '^reviewed:' "$entry" 2>/dev/null | sed 's/^reviewed: *//' | tr -d '[:space:]' || true)
        if [ -z "$reviewed" ] || [ "$reviewed" = "null" ] || [ "$reviewed" = "" ]; then
          echo "$entry"
        fi
      done | head -"$LIMIT"
      ;;
    last)
      # Most recent entries by modification time
      find "$ENTRIES_DIR" -name '*.md' -type f -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -"$LIMIT"
      ;;
    topic)
      # Entries matching tag or topic
      grep -rl "$TOPIC" "$ENTRIES_DIR" --include='*.md' 2>/dev/null | head -"$LIMIT"
      ;;
    entry)
      # Specific entry
      local entry_file="$ENTRIES_DIR/${SPECIFIC_ENTRY}.md"
      [ -f "$entry_file" ] && echo "$entry_file"
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════
# ENTRY SUMMARY GENERATION
# ═══════════════════════════════════════════════════════════
generate_summary() {
  local entry_path="$1"
  local entry_name
  entry_name=$(basename "$entry_path" .md)

  # Extract frontmatter fields
  local title source date_entry status reviewed
  title=$(grep -m1 '^title:' "$entry_path" 2>/dev/null | sed 's/^title: *"//;s/"$//' || echo "$entry_name")
  source=$(grep -m1 '^source:' "$entry_path" 2>/dev/null | sed 's/^source: *"//;s/"$//' || echo "unknown")
  date_entry=$(grep -m1 '^date_entry:' "$entry_path" 2>/dev/null | sed 's/^date_entry: *//' || echo "unknown")
  status=$(grep -m1 '^status:' "$entry_path" 2>/dev/null | sed 's/^status: *//' || echo "unknown")
  reviewed=$(grep -m1 '^reviewed:' "$entry_path" 2>/dev/null | sed 's/^reviewed: *//' | tr -d '[:space:]' || echo "null")

  # Count linked concepts
  local concept_count
  concept_count=$(grep -c '\[\[' "$entry_path" 2>/dev/null || echo 0)

  # Get first paragraph of summary
  local summary
  summary=$(sed -n '/^## Summary/,/^##/p' "$entry_path" 2>/dev/null | head -5 | tail -4 | tr '\n' ' ')

  cat << EOF
═══════════════════════════════════════════════
Entry: $entry_name
Title: $title
Source: $source
Date: $date_entry | Status: $status | Reviewed: $reviewed
Links: $concept_count wikilinks

Summary: $summary
═══════════════════════════════════════════════
EOF
}

# ═══════════════════════════════════════════════════════════
# INTERACTIVE REVIEW LOOP
# ═══════════════════════════════════════════════════════════
review_interactive() {
  local entries
  entries=$(select_entries)

  if [ -z "$entries" ]; then
    echo "No entries found matching your criteria."
    log "Review pass: No entries found (mode=$MODE)"
    exit 0
  fi

  local count=0
  local reviewed_count=0
  local enriched_count=0
  local skipped_count=0

  while IFS= read -r entry_path; do
    [ -f "$entry_path" ] || continue
    count=$((count + 1))
    local entry_name
    entry_name=$(basename "$entry_path" .md)

    echo ""
    generate_summary "$entry_path"
    echo ""
    echo "Options: [g]ood / [e]nrich / [u]pdate / [s]kip / [q]uit"
    echo -n "> "

    if $INTERACTIVE; then
      read -r response
    else
      response="g"  # Batch mode: just mark as reviewed
    fi

    case "$response" in
      g|good)
        # Mark as reviewed
        update_review_status "$entry_path" "$(date +%Y-%m-%d)" "reviewed"
        reviewed_count=$((reviewed_count + 1))
        echo "✓ Marked as reviewed."
        ;;
      e|enrich)
        # Prompt for enrichment instructions
        if $INTERACTIVE; then
          echo "What should be enriched? (e.g., 'expand on X, add context about Y')"
          echo -n "> "
          read -r enrichment
          enrich_entry "$entry_path" "$enrichment"
          enriched_count=$((enriched_count + 1))
        else
          echo "Enrichment requires --interactive mode."
          skipped_count=$((skipped_count + 1))
        fi
        ;;
      u|update)
        # Prompt for specific updates
        if $INTERACTIVE; then
          echo "What connections or updates are needed? (e.g., 'this contradicts [[Other Entry]]')"
          echo -n "> "
          read -r update_instructions
          update_entry "$entry_path" "$update_instructions"
          enriched_count=$((enriched_count + 1))
        else
          echo "Updates require --interactive mode."
          skipped_count=$((skipped_count + 1))
        fi
        ;;
      s|skip)
        skipped_count=$((skipped_count + 1))
        echo "⊘ Skipped."
        ;;
      q|quit)
        echo ""
        break
        ;;
      *)
        echo "Treating as enrichment instructions..."
        enrich_entry "$entry_path" "$response"
        enriched_count=$((enriched_count + 1))
        ;;
    esac
  done <<< "$entries"

  # Summary
  echo ""
  echo "═══════════════════════════════════════════"
  echo "Review Summary"
  echo "═══════════════════════════════════════════"
  echo "Entries reviewed: $count"
  echo "Marked reviewed: $reviewed_count"
  echo "Enriched/updated: $enriched_count"
  echo "Skipped: $skipped_count"
  echo "═══════════════════════════════════════════"

  # Log
  append_log_md "review" "Review pass ($MODE, $count entries)" \
    "- Reviewed: $reviewed_count
- Enriched: $enriched_count
- Skipped: $skipped_count"

  auto_commit "review" "Reviewed $count entries ($reviewed_count reviewed, $enriched_count enriched)"
}

# ═══════════════════════════════════════════════════════════
# UPDATE HELPERS
# ═══════════════════════════════════════════════════════════
update_review_status() {
  local entry_path="$1"
  local date="$2"
  local notes="$3"

  # Update reviewed field in frontmatter
  if grep -q '^reviewed:' "$entry_path" 2>/dev/null; then
    sed -i "s/^reviewed:.*/reviewed: $date/" "$entry_path"
  else
    # Add after status line
    sed -i "/^status:/a reviewed: $date" "$entry_path"
  fi

  # Update review_notes
  if grep -q '^review_notes:' "$entry_path" 2>/dev/null; then
    sed -i "s/^review_notes:.*/review_notes: \"$notes\"/" "$entry_path"
  else
    sed -i "/^reviewed:/a review_notes: \"$notes\"" "$entry_path"
  fi
}

enrich_entry() {
  local entry_path="$1"
  local instructions="$2"
  local entry_name
  entry_name=$(basename "$entry_path" .md)

  local prompt="
VAULT LOCATION: $VAULT_PATH

TASK: Enrich the entry note '$entry_name' based on user feedback.

USER FEEDBACK: $instructions

INSTRUCTIONS:
1. Read the full entry at '$entry_path'
2. Read the wiki index at '06-Config/wiki-index.md' for context
3. Enrich the entry based on the user's instructions:
   - Add depth to specific sections
   - Expand on insights that were mentioned
   - Add new connections or context
4. If the feedback reveals new connections to other entries, UPDATE those entries too with cross-references.
5. Update the 'reviewed:' and 'review_notes:' frontmatter fields.
6. Humanize all new prose using the Humanizer skill.
7. Update '06-Config/wiki-index.md' if new concepts were created.
8. Append to '06-Config/log.md':
   ## [$(date +%Y-%m-%d)] review | $entry_name (enriched)
   - Feedback: $instructions
   - Sections updated: [list]

CRITICAL RULES:
- Use [[wikilinks]] for all internal links
- Quote wikilinks in YAML frontmatter
- Do NOT modify 07-WIP/
"

  if run_with_retry "Review enrichment: $entry_name" "$prompt"; then
    update_review_status "$entry_path" "$(date +%Y-%m-%d)" "enriched: $instructions"
    echo "✓ Entry enriched."
    log "Review enrichment: $entry_name — $instructions"
  else
    echo "✗ Enrichment failed for $entry_name"
  fi
}

update_entry() {
  local entry_path="$1"
  local instructions="$2"
  local entry_name
  entry_name=$(basename "$entry_path" .md)

  local prompt="
VAULT LOCATION: $VAULT_PATH

TASK: Update the entry '$entry_name' and related entries based on user feedback.

USER FEEDBACK: $instructions

INSTRUCTIONS:
1. Read the entry at '$entry_path'
2. Read the wiki index at '06-Config/wiki-index.md'
3. Based on the feedback, make updates:
   - If connections are mentioned, add wikilinks to both sides
   - If contradictions are found, note them in both entries' Open questions
   - If new insights emerged, add them to the appropriate sections
4. For any other entry mentioned in the feedback (e.g., [[Other Entry]]):
   - Read that entry
   - Add reciprocal links/connections
   - Update its 'Linked concepts' section if needed
5. Update frontmatter: reviewed: $(date +%Y-%m-%d), review_notes: [feedback summary]
6. If typed edges are relevant, append to '06-Config/edges.tsv':
   source<tab>target<tab>type<tab>description
7. Humanize all new prose.
8. Append to '06-Config/log.md':
   ## [$(date +%Y-%m-%d)] review | $entry_name (connections updated)
   - Feedback: $instructions
   - Entries updated: [list]

CRITICAL RULES:
- Use [[wikilinks]] for all internal links
- Quote wikilinks in YAML frontmatter
- Do NOT modify 07-WIP/
"

  if run_with_retry "Review update: $entry_name" "$prompt"; then
    update_review_status "$entry_path" "$(date +%Y-%m-%d)" "updated: $instructions"
    echo "✓ Entry updated."
    log "Review update: $entry_name — $instructions"
  else
    echo "✗ Update failed for $entry_name"
  fi
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════
acquire_lock "review-pass" || exit 1

setup_directory_structure
bootstrap_url_index

log "=== Starting review pass (mode=$MODE, limit=$LIMIT, interactive=$INTERACTIVE) ==="
review_interactive
log "=== Review pass complete ==="
