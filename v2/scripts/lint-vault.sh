#!/usr/bin/env bash
# ============================================================================
# v2.2: Lint Vault — Karpathy-style health checks on the wiki
# ============================================================================
# Changes from v2.1:
#   - Sources common library (lib/common.sh)
#   - Removed mandatory ELI5 section check (now template-aware)
#   - Added review status check (entries older than 7 days, unreviewed)
#   - Added edges.tsv consistency check
#   - Git auto-commit after lint
#
# Writes report to: $VAULT_PATH/Meta/Scripts/lint-report.md
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

REPORT_FILE="$VAULT_PATH/Meta/Scripts/lint-report.md"
REPORT_DATE=$(date +%Y-%m-%d)

mkdir -p "$VAULT_PATH/Meta/Scripts"

echo "# Lint Report — $REPORT_DATE (v2.2)" > "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "> Karpathy-style linting: catches what the LLM misses." >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

total_issues=0

# ═══════════════════════════════════════════════════════════
# 1. Orphaned Notes: files with zero incoming wikilinks
# ═══════════════════════════════════════════════════════════
echo "## 1. Orphaned Notes (no incoming wikilinks)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
orphan_count=0

for dir in "04-Wiki/entries" "04-Wiki/concepts" "04-Wiki/mocs" "04-Wiki/sources"; do
  dir_path="$VAULT_PATH/$dir"
  [ -d "$dir_path" ] || continue

  for note in "$dir_path"/*.md; do
    [ -f "$note" ] || continue
    note_name=$(basename "$note" .md)

    if ! grep -rF "[[$note_name]]" "$VAULT_PATH" --include="*.md" \
      --exclude-dir=.git 2>/dev/null | grep -v "^$note:" | grep -q .; then
      echo "- [$note_name]($dir/$note_name.md)" >> "$REPORT_FILE"
      orphan_count=$((orphan_count + 1))
    fi
  done
done

if [ $orphan_count -eq 0 ]; then
  echo "None found. All notes have at least one incoming wikilink." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $orphan_count orphaned notes**" >> "$REPORT_FILE"
  echo "Action: Create backlinks, add to an MoC, or archive if obsolete." >> "$REPORT_FILE"
  total_issues=$((total_issues + orphan_count))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 2. Unreviewed Entries
# ═══════════════════════════════════════════════════════════
echo "## 2. Unreviewed Entries (reviewed: null)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
unreviewed_count=0

if [ -d "$VAULT_PATH/04-Wiki/entries" ]; then
  for entry in "$VAULT_PATH/04-Wiki/entries"/*.md; do
    [ -f "$entry" ] || continue
    reviewed=$(grep -m1 '^reviewed:' "$entry" 2>/dev/null | sed 's/^reviewed: *//' | tr -d '[:space:]' || true)
    if [ -z "$reviewed" ] || [ "$reviewed" = "null" ] || [ "$reviewed" = "" ]; then
      entry_name=$(basename "$entry" .md)
      entry_date=$(grep -m1 '^date_entry:' "$entry" 2>/dev/null | sed 's/^date_entry: *//' || echo "unknown")
      echo "- [$entry_name](04-Wiki/entries/$entry_name.md) — created: $entry_date" >> "$REPORT_FILE"
      unreviewed_count=$((unreviewed_count + 1))
    fi
  done
fi

if [ $unreviewed_count -eq 0 ]; then
  echo "All entries have been reviewed." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $unreviewed_count unreviewed entries**" >> "$REPORT_FILE"
  echo "Action: Run \`bash review-pass.sh --untouched\` to review them." >> "$REPORT_FILE"
  total_issues=$((total_issues + unreviewed_count))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 3. Stale Reviews: status: review older than 14 days
# ═══════════════════════════════════════════════════════════
echo "## 3. Stale Reviews (status: review, >14 days old)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
stale_count=0
cutoff_date=$(date -d "14 days ago" +%Y-%m-%d 2>/dev/null || date -v-14d +%Y-%m-%d 2>/dev/null || echo "")

if [ -n "$cutoff_date" ]; then
  for dir in "04-Wiki/entries" "04-Wiki/concepts"; do
    dir_path="$VAULT_PATH/$dir"
    [ -d "$dir_path" ] || continue

    for note in "$dir_path"/*.md; do
      [ -f "$note" ] || continue
      note_date=$(grep -m1 'date_entry:\|updated:' "$note" 2>/dev/null | head -1 | sed 's/.*date_entry: *//; s/.*updated: *//' | tr -d '[:space:]' || true)
      note_status=$(grep -m1 'status:' "$note" 2>/dev/null | sed 's/.*status: *//' | tr -d '[:space:]' || true)

      if [ "$note_status" = "review" ] && [ -n "$note_date" ] && [[ "$note_date" < "$cutoff_date" ]]; then
        note_name=$(basename "$note" .md)
        echo "- [$note_name]($dir/$note_name.md) — dated: $note_date" >> "$REPORT_FILE"
        stale_count=$((stale_count + 1))
      fi
    done
  done
fi

if [ $stale_count -eq 0 ]; then
  echo "None found." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $stale_count stale reviews**" >> "$REPORT_FILE"
  echo "Action: Review these notes, update status to 'evergreen' or 'seed'." >> "$REPORT_FILE"
  total_issues=$((total_issues + stale_count))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 4. Broken Wikilinks
# ═══════════════════════════════════════════════════════════
echo "## 4. Broken Wikilinks (link targets don't exist)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
broken_count=0

for dir in "04-Wiki/entries" "04-Wiki/concepts" "04-Wiki/mocs" "04-Wiki/sources"; do
  dir_path="$VAULT_PATH/$dir"
  [ -d "$dir_path" ] || continue

  for note in "$dir_path"/*.md; do
    [ -f "$note" ] || continue
    note_rel="${note#$VAULT_PATH/}"

    while read -r link_target; do
      [ -z "$link_target" ] && continue
      clean_target=$(echo "$link_target" | sed 's/[#|].*//' | tr -d '[:space:]')
      [ -z "$clean_target" ] && continue

      target_file=$(find "$VAULT_PATH" -name "${clean_target}.md" -not -path "*/.git/*" 2>/dev/null | head -1)
      if [ -z "$target_file" ]; then
        echo "- In [$note_rel](#) → [[$link_target]]" >> "$REPORT_FILE"
        broken_count=$((broken_count + 1))
      fi
    done < <(grep -oE '\[\[.+?\]\]' "$note" 2>/dev/null | sed 's/\[\[//;s/\]\]//')
  done
done

if [ $broken_count -eq 0 ]; then
  echo "No broken wikilinks found." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $broken_count broken links**" >> "$REPORT_FILE"
  echo "Action: Create missing notes or fix the wikilinks." >> "$REPORT_FILE"
  total_issues=$((total_issues + broken_count))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 5. Empty or Near-Empty Notes (< 50 characters body)
# ═══════════════════════════════════════════════════════════
echo "## 5. Empty or Near-Empty Notes (< 50 chars body)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
empty_count=0

for dir in "04-Wiki/entries" "04-Wiki/concepts" "04-Wiki/mocs" "04-Wiki/sources"; do
  dir_path="$VAULT_PATH/$dir"
  [ -d "$dir_path" ] || continue

  for note in "$dir_path"/*.md; do
    [ -f "$note" ] || continue
    body_chars=$(sed '/^---$/,/^---$/d; /^#/d' "$note" 2>/dev/null | tr -d '[:space:]' | wc -c)
    if [ "$body_chars" -lt 50 ]; then
      note_name=$(basename "$note" .md)
      echo "- [$note_name]($dir/$note_name.md) — $body_chars chars" >> "$REPORT_FILE"
      empty_count=$((empty_count + 1))
    fi
  done
done

if [ $empty_count -eq 0 ]; then
  echo "None found." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $empty_count near-empty notes**" >> "$REPORT_FILE"
  echo "Action: Delete or expand these notes." >> "$REPORT_FILE"
  total_issues=$((total_issues + empty_count))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 6. Concept Structure Checks
# ═══════════════════════════════════════════════════════════
echo "## 6. Concept Structure Checks" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
conflict_count=0

if [ -d "$VAULT_PATH/04-Wiki/concepts" ]; then
  for note in "$VAULT_PATH/04-Wiki/concepts"/*.md; do
    [ -f "$note" ] || continue
    note_name=$(basename "$note" .md)
    entry_refs=$(grep -A20 'entry_refs:' "$note" 2>/dev/null | grep -oE '\[\[.+?\]\]' | sed 's/\[\[//;s/\]\]//' || true)
    if [ -z "$entry_refs" ]; then
      echo "- **[$note_name]**: Concept has no Entry references — orphaned concept?" >> "$REPORT_FILE"
      conflict_count=$((conflict_count + 1))
    fi
  done
fi

if [ $conflict_count -eq 0 ]; then
  echo "All concepts have Entry references." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $conflict_count structural issues found**" >> "$REPORT_FILE"
  total_issues=$((total_issues + conflict_count))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 7. Orphaned Concepts (no Entry references them)
# ═══════════════════════════════════════════════════════════
echo "## 7. Orphaned Concepts (no Entry links to them)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
orphan_concept_count=0

if [ -d "$VAULT_PATH/04-Wiki/concepts" ]; then
  for concept in "$VAULT_PATH/04-Wiki/concepts"/*.md; do
    [ -f "$concept" ] || continue
    concept_name=$(basename "$concept" .md)

    has_backlink=false
    for entry in "$VAULT_PATH/04-Wiki/entries"/*.md; do
      [ -f "$entry" ] || continue
      if grep -qF "[[$concept_name]]" "$entry" 2>/dev/null; then
        has_backlink=true
        break
      fi
    done

    if [ "$has_backlink" = false ]; then
      if ! grep -qF "[[$concept_name]]" "$concept" 2>/dev/null; then
        echo "- [$concept_name](04-Wiki/concepts/$concept_name.md)" >> "$REPORT_FILE"
        orphan_concept_count=$((orphan_concept_count + 1))
      fi
    fi
  done
fi

if [ $orphan_concept_count -eq 0 ]; then
  echo "All concepts are referenced by at least one Entry." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $orphan_concept_count orphaned concepts**" >> "$REPORT_FILE"
  echo "Action: Add backlinks to Entries, or archive if the concept is deprecated." >> "$REPORT_FILE"
  total_issues=$((total_issues + orphan_concept_count))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 8. Wiki Index Drift
# ═══════════════════════════════════════════════════════════
echo "## 8. Wiki Index Drift (index vs actual notes)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
drift_count=0

if [ -f "$VAULT_PATH/06-Config/wiki-index.md" ]; then
  index_entry_count=$(grep -c '(entry)' "$VAULT_PATH/06-Config/wiki-index.md" 2>/dev/null || echo 0)
  index_concept_count=$(grep -c '(concept)' "$VAULT_PATH/06-Config/wiki-index.md" 2>/dev/null || echo 0)

  actual_entry_count=$(find "$VAULT_PATH/04-Wiki/entries" -name '*.md' 2>/dev/null | wc -l)
  actual_concept_count=$(find "$VAULT_PATH/04-Wiki/concepts" -name '*.md' 2>/dev/null | wc -l)

  if [ "$index_entry_count" -ne "$actual_entry_count" ]; then
    echo "- **Entry mismatch**: Index lists $index_entry_count, actual files: $actual_entry_count" >> "$REPORT_FILE"
    drift_count=$((drift_count + 1))
  fi

  if [ "$index_concept_count" -ne "$actual_concept_count" ]; then
    echo "- **Concept mismatch**: Index lists $index_concept_count, actual files: $actual_concept_count" >> "$REPORT_FILE"
    drift_count=$((drift_count + 1))
  fi

  if [ $drift_count -eq 0 ]; then
    echo "Wiki index is in sync with actual notes." >> "$REPORT_FILE"
  else
    echo "" >> "$REPORT_FILE"
    echo "**Total: $drift_count drift issues**" >> "$REPORT_FILE"
    echo "Action: Run \`bash reindex.sh\` to rebuild the wiki index." >> "$REPORT_FILE"
  fi
else
  echo "Wiki index file not found. Run \`bash reindex.sh\` to create it." >> "$REPORT_FILE"
  drift_count=1
fi

total_issues=$((total_issues + drift_count))

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 9. Edges Consistency Check (v2.2)
# ═══════════════════════════════════════════════════════════
echo "## 9. Edges Consistency (edges.tsv)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
edge_issues=0

if [ -f "$VAULT_PATH/06-Config/edges.tsv" ]; then
  total_edges=$(( $(wc -l < "$VAULT_PATH/06-Config/edges.tsv") - 1 ))
  [ "$total_edges" -lt 0 ] && total_edges=0

  # Check for edges referencing non-existent notes
  while IFS=$'\t' read -r source target type desc; do
    [ "$source" = "source" ] && continue  # Skip header
    [ -z "$source" ] && continue

    if ! find "$VAULT_PATH/04-Wiki" -name "${source}.md" 2>/dev/null | grep -q .; then
      echo "- Source '$source' in edge not found as a note" >> "$REPORT_FILE"
      edge_issues=$((edge_issues + 1))
    fi
    if ! find "$VAULT_PATH/04-Wiki" -name "${target}.md" 2>/dev/null | grep -q .; then
      echo "- Target '$target' in edge not found as a note" >> "$REPORT_FILE"
      edge_issues=$((edge_issues + 1))
    fi
  done < "$VAULT_PATH/06-Config/edges.tsv"

  echo "Total edges: $total_edges" >> "$REPORT_FILE"
  if [ $edge_issues -eq 0 ]; then
    echo "All edges reference existing notes." >> "$REPORT_FILE"
  else
    echo "" >> "$REPORT_FILE"
    echo "**Total: $edge_issues edge consistency issues**" >> "$REPORT_FILE"
  fi
else
  echo "edges.tsv not found. Run compile-pass.sh to create typed edges." >> "$REPORT_FILE"
  edge_issues=1
fi

total_issues=$((total_issues + edge_issues))
echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════
echo "---" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "## Summary" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "| Check | Issues |" >> "$REPORT_FILE"
echo "|-------|--------|" >> "$REPORT_FILE"
echo "| Orphaned notes | $orphan_count |" >> "$REPORT_FILE"
echo "| Unreviewed entries | $unreviewed_count |" >> "$REPORT_FILE"
echo "| Stale reviews | $stale_count |" >> "$REPORT_FILE"
echo "| Broken wikilinks | $broken_count |" >> "$REPORT_FILE"
echo "| Near-empty notes | $empty_count |" >> "$REPORT_FILE"
echo "| Concept structure issues | $conflict_count |" >> "$REPORT_FILE"
echo "| Orphaned concepts | $orphan_concept_count |" >> "$REPORT_FILE"
echo "| Wiki index drift | $drift_count |" >> "$REPORT_FILE"
echo "| Edges consistency | $edge_issues |" >> "$REPORT_FILE"
echo "| **TOTAL** | **$total_issues** |" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "*Run lint-vault.sh (v2.2) to regenerate this report.*" >> "$REPORT_FILE"

# Log entry
append_log_md "lint" "Health check" \
  "- Orphaned notes: $orphan_count
- Unreviewed entries: $unreviewed_count
- Stale reviews: $stale_count
- Broken wikilinks: $broken_count
- Near-empty notes: $empty_count
- Concept structure issues: $conflict_count
- Orphaned concepts: $orphan_concept_count
- Wiki index drift: $drift_count
- Edges consistency: $edge_issues
- Total issues: $total_issues
- Full report: Meta/Scripts/lint-report.md"

auto_commit "lint" "Health check ($total_issues total issues)"

echo "Lint report written to $REPORT_FILE"
echo "Summary: $orphan_count orphaned, $unreviewed_count unreviewed, $stale_count stale, $broken_count broken links, $total_issues total issues"
