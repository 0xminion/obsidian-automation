#!/usr/bin/env bash
# ============================================================================
# v2.2: Reindex — Full rebuild of wiki-index.md from scratch
# ============================================================================
# Think fsck for your wiki. Scans every Entry, Concept, and MoC,
# reads their frontmatter, and rebuilds wiki-index.md from zero.
# Run when lint flags index drift or after manual vault surgery.
#
# Usage: VAULT_PATH="$HOME/MyVault" bash reindex.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

acquire_lock "reindex" || exit 1

INDEX_FILE="$VAULT_PATH/06-Config/wiki-index.md"
REPORT_DATE=$(date +%Y-%m-%d)

log "=== Starting full reindex ==="

# ═══════════════════════════════════════════════════════════
# REBUILD INDEX FROM SCRATCH
# ═══════════════════════════════════════════════════════════
cat > "$INDEX_FILE" << 'HEADER'
# Wiki Index

Auto-maintained table of contents for the knowledge base.
Each entry and concept has a 1-sentence summary for retrieval.
This index is the primary retrieval layer — the LLM reads this
to find relevant notes instead of using RAG.

---

HEADER

entries_added=0
concepts_added=0
mocs_added=0

# Scan Entries
echo "## Entries" >> "$INDEX_FILE"
echo "" >> "$INDEX_FILE"

if [ -d "$VAULT_PATH/04-Wiki/entries" ]; then
  for entry in "$VAULT_PATH/04-Wiki/entries"/*.md; do
    [ -f "$entry" ] || continue
    note_name=$(basename "$entry" .md)
    title=$(grep -m1 '^title:' "$entry" 2>/dev/null | sed 's/^title: *"//;s/"$//' || echo "$note_name")

    # Get first sentence of summary as description
    summary=$(sed -n '/^## Summary/,/^##/p' "$entry" 2>/dev/null \
      | grep -v '^##' | head -2 | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
    [ -z "$summary" ] && summary="$title"

    echo "- [[$note_name]]: $summary (entry)" >> "$INDEX_FILE"
    entries_added=$((entries_added + 1))
  done
fi

echo "" >> "$INDEX_FILE"

# Scan Concepts
echo "## Concepts" >> "$INDEX_FILE"
echo "" >> "$INDEX_FILE"

if [ -d "$VAULT_PATH/04-Wiki/concepts" ]; then
  for concept in "$VAULT_PATH/04-Wiki/concepts"/*.md; do
    [ -f "$concept" ] || continue
    note_name=$(basename "$concept" .md)
    title=$(grep -m1 '^title:' "$concept" 2>/dev/null | sed 's/^title: *"//;s/"$//' || echo "$note_name")

    # Get first paragraph after heading
    body=$(sed -n '/^# /,/^##/p' "$concept" 2>/dev/null \
      | grep -v '^#' | head -2 | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
    [ -z "$body" ] && body="$title"

    echo "- [[$note_name]]: $body (concept)" >> "$INDEX_FILE"
    concepts_added=$((concepts_added + 1))
  done
fi

echo "" >> "$INDEX_FILE"

# Scan MoCs
if [ -d "$VAULT_PATH/04-Wiki/mocs" ]; then
  moc_count=$(find "$VAULT_PATH/04-Wiki/mocs" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$moc_count" -gt 0 ]; then
    echo "## Maps of Content" >> "$INDEX_FILE"
    echo "" >> "$INDEX_FILE"
    for moc in "$VAULT_PATH/04-Wiki/mocs"/*.md; do
      [ -f "$moc" ] || continue
      note_name=$(basename "$moc" .md)
      title=$(grep -m1 '^title:' "$moc" 2>/dev/null | sed 's/^title: *"//;s/"$//' || echo "$note_name")
      overview=$(sed -n '/^## Overview/,/^##/p' "$moc" 2>/dev/null \
        | grep -v '^##' | head -2 | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
      [ -z "$overview" ] && overview="$title"
      echo "- [[$note_name]]: $overview (moc)" >> "$INDEX_FILE"
      mocs_added=$((mocs_added + 1))
    done
    echo "" >> "$INDEX_FILE"
  fi
fi

# ═══════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════
echo "---" >> "$INDEX_FILE"
echo "" >> "$INDEX_FILE"
echo "*Reindexed on $REPORT_DATE: $entries_added entries, $concepts_added concepts, $mocs_added MoCs*" >> "$INDEX_FILE"

log "Reindex complete: $entries_added entries, $concepts_added concepts, $mocs_added MoCs"

append_log_md "reindex" "Full index rebuild" \
  "- Entries indexed: $entries_added
- Concepts indexed: $concepts_added
- MoCs indexed: $mocs_added
- Output: 06-Config/wiki-index.md"

auto_commit "reindex" "Full wiki index rebuild ($entries_added entries, $concepts_added concepts)"

echo "Reindex complete: $entries_added entries, $concepts_added concepts, $mocs_added MoCs"
echo "Index written to $INDEX_FILE"
