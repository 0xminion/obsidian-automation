#!/usr/bin/env bash
# ============================================================================
# v2: Lint Vault — Karpathy-style health checks on the wiki
# ============================================================================
# Runs NON-LLM checks to find:
# 1. Orphaned notes (no incoming wikilinks)
# 2. Stale reviews (status: review older than N days)
# 3. Broken wikilinks (link targets that don't exist)
# 4. Empty or near-empty notes (< 50 chars body)
# 5. Concept inconsistencies (same fact stated differently across notes)
# 6. Entry concept drift (entry_ref points to concept that no longer mentions entry)
# 7. Orphaned concepts (no Entry references them)
# 8. Wiki index drift (index out of sync with actual notes)
#
# Writes report to: $VAULT_PATH/Meta/Scripts/lint-report.md
# ============================================================================

set -uo pipefail

VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
REPORT_FILE="$VAULT_PATH/Meta/Scripts/lint-report.md"
REPORT_DATE=$(date +%Y-%m-%d)

mkdir -p "$VAULT_PATH/Meta/Scripts"

echo "# Lint Report — $REPORT_DATE (v2)" > "$REPORT_FILE"
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

for dir in "wiki/entries" "wiki/concepts" "wiki/mocs" "wiki/sources"; do
  dir_path="$VAULT_PATH/$dir"
  [ -d "$dir_path" ] || continue

  for note in "$dir_path"/*.md; do
    [ -f "$note" ] || continue
    note_name=$(basename "$note" .md)

    # Search for wikilinks to this note in all vault files except itself
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
# 2. Stale Reviews: status: review older than 14 days
# ═══════════════════════════════════════════════════════════
echo "## 2. Stale Reviews (status: review, >14 days old)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
stale_count=0
cutoff_date=$(date -d "14 days ago" +%Y-%m-%d 2>/dev/null || date -v-14d +%Y-%m-%d 2>/dev/null || echo "")

if [ -n "$cutoff_date" ]; then
  for dir in "wiki/entries" "wiki/concepts"; do
    dir_path="$VAULT_PATH/$dir"
    [ -d "$dir_path" ] || continue

    for note in "$dir_path"/*.md; do
      [ -f "$note" ] || continue
      # Check date_entry for entries, updated for concepts
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
# 3. Broken Wikilinks: link targets that don't exist
# ═══════════════════════════════════════════════════════════
echo "## 3. Broken Wikilinks (link targets don't exist)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
broken_count=0

for dir in "wiki/entries" "wiki/concepts" "wiki/mocs" "wiki/sources"; do
  dir_path="$VAULT_PATH/$dir"
  [ -d "$dir_path" ] || continue

  for note in "$dir_path"/*.md; do
    [ -f "$note" ] || continue
    note_rel="${note#$VAULT_PATH/}"

    # Extract wikilink targets from this note
    while read -r link_target; do
      [ -z "$link_target" ] && continue
      # Clean the link (strip #Headings and |Display Text)
      clean_target=$(echo "$link_target" | sed 's/[#|].*//' | tr -d '[:space:]')
      [ -z "$clean_target" ] && continue

      # Check if target file exists anywhere in the vault
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
# 4. Empty or Near-Empty Notes (< 50 characters body)
# ═══════════════════════════════════════════════════════════
echo "## 4. Empty or Near-Empty Notes (< 50 chars body)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
empty_count=0

for dir in "wiki/entries" "wiki/concepts" "wiki/mocs" "wiki/sources"; do
  dir_path="$VAULT_PATH/$dir"
  [ -d "$dir_path" ] || continue

  for note in "$dir_path"/*.md; do
    [ -f "$note" ] || continue
    # Count non-frontmatter, non-whitespace characters (skip yaml and headings)
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
# 5. Concept Inconsistencies (same fact stated differently)
# ═══════════════════════════════════════════════════════════
echo "## 5. Concept Inconsistencies" >> "$REPORT_FILE"
echo "(Facts stated differently across notes — requires LLM analysis)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "This check requires reading content and comparing factual claims." >> "$REPORT_FILE"
echo "Use compile-pass.sh or a LLM-based review to find inconsistencies." >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Quick check: look for concepts with conflicting status
conflict_count=0
for note in "$VAULT_PATH/wiki/concepts"/*.md; do
  [ -f "$note" ] || continue
  note_name=$(basename "$note" .md)
  # Check if the concept references entries that disagree on source facts
  entry_refs=$(grep -A20 'entry_refs:' "$note" 2>/dev/null | grep -oE '\[\[.+?\]\]' | sed 's/\[\[//;s/\]\]//' || true)
  if [ -z "$entry_refs" ]; then
    echo "- **[$note_name]**: Concept has no Entry references — orphaned concept?" >> "$REPORT_FILE"
    conflict_count=$((conflict_count + 1))
  fi
done

if [ $conflict_count -eq 0 ]; then
  echo "Quick structural check: All concepts have Entry references." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $conflict_count structural issues found**" >> "$REPORT_FILE"
  total_issues=$((total_issues + conflict_count))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 6. Orphaned Concepts (no Entry references them)
# ═══════════════════════════════════════════════════════════
echo "## 6. Orphaned Concepts (no Entry links to them)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
orphan_concept_count=0

if [ -d "$VAULT_PATH/wiki/concepts" ]; then
  for concept in "$VAULT_PATH/wiki/concepts"/*.md; do
    [ -f "$concept" ] || continue
    concept_name=$(basename "$concept" .md)

    # Check if any Entry links to this concept
    has_backlink=false
    for entry in "$VAULT_PATH/wiki/entries"/*.md; do
      [ -f "$entry" ] || continue
      if grep -qF "[[$concept_name]]" "$entry" 2>/dev/null; then
        has_backlink=true
        break
      fi
    done

    if [ "$has_backlink" = false ]; then
      # Check if the concept is self-referencing (in its own entry_refs)
      if ! grep -qF "[[$concept_name]]" "$concept" 2>/dev/null; then
        echo "- [$concept_name](wiki/concepts/$concept_name.md)" >> "$REPORT_FILE"
        orphan_concept_count=$((orphan_concept_count + 1))
      fi
    fi
  done
fi

if [ $orphan_concept_count -eq 0 ]; then
  echo "None found. All concepts are referenced by at least one Entry." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $orphan_concept_count orphaned concepts**" >> "$REPORT_FILE"
  echo "Action: Add backlinks to Entries, or archive if the concept is deprecated." >> "$REPORT_FILE"
  total_issues=$((total_issues + orphan_concept_count))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 7. Wiki Index Drift (index out of sync with actual notes)
# ═══════════════════════════════════════════════════════════
echo "## 7. Wiki Index Drift (index vs actual notes)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
drift_count=0

if [ -f "$VAULT_PATH/config/wiki-index.md" ]; then
  # Count entries in the index
  index_entry_count=$(grep -c '(entry)' "$VAULT_PATH/config/wiki-index.md" 2>/dev/null || echo 0)
  index_concept_count=$(grep -c '(concept)' "$VAULT_PATH/config/wiki-index.md" 2>/dev/null || echo 0)

  # Count actual files
  actual_entry_count=$(find "$VAULT_PATH/wiki/entries" -name '*.md' 2>/dev/null | wc -l)
  actual_concept_count=$(find "$VAULT_PATH/wiki/concepts" -name '*.md' 2>/dev/null | wc -l)

  if [ "$index_entry_count" -ne "$actual_entry_count" ]; then
    echo "- **Entry mismatch**: Index lists $index_entry_count, actual files: $actual_entry_count" >> "$REPORT_FILE"
    drift_count=$((drift_count + 1))
  fi

  if [ "$index_concept_count" -ne "$actual_concept_count" ]; then
    echo "- **Concept mismatch**: Index lists $index_concept_count, actual files: $actual_concept_count" >> "$REPORT_FILE"
    drift_count=$((drift_count + 1))
  fi

  # Check for index entries that don't exist as files
  while read -r idx_note; do
    [ -z "$idx_note" ] && continue
    if ! find "$VAULT_PATH/wiki" -name "${idx_note}.md" 2>/dev/null | grep -q .; then
      echo "- **[$idx_note]**: Listed in index but file not found" >> "$REPORT_FILE"
      drift_count=$((drift_count + 1))
    fi
  done < <(grep -oE '\[\[.+?\]\]' "$VAULT_PATH/config/wiki-index.md" 2>/dev/null | sed 's/\[\[//;s/\]\]//')

  if [ $drift_count -eq 0 ]; then
    echo "Wiki index is in sync with actual notes." >> "$REPORT_FILE"
  else
    echo "" >> "$REPORT_FILE"
    echo "**Total: $drift_count drift issues**" >> "$REPORT_FILE"
    echo "Action: Run compile-pass.sh to rebuild the wiki index." >> "$REPORT_FILE"
  fi
else
  echo "Wiki index file not found. Create it by running compile-pass.sh." >> "$REPORT_FILE"
  drift_count=1
fi

total_issues=$((total_issues + drift_count))

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 8. Entries Missing Required Sections
# ═══════════════════════════════════════════════════════════
echo "## 8. Entries Missing Required Sections" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
missing_section_count=0
required_sections=("## Summary" "## ELI5 insights" "### Core insights" "### Other takeaways" "## Diagrams" "## Open questions" "## Linked concepts")

if [ -d "$VAULT_PATH/wiki/entries" ]; then
  for entry in "$VAULT_PATH/wiki/entries"/*.md; do
    [ -f "$entry" ] || continue
    entry_name=$(basename "$entry" .md)
    missing=""

    for section in "${required_sections[@]}"; do
      if ! grep -qF "$section" "$entry" 2>/dev/null; then
        missing="${missing}${section}, "
      fi
    done

    if [ -n "$missing" ]; then
      missing="${missing%, }"  # Remove trailing comma
      echo "- [$entry_name](wiki/entries/$entry_name.md) — missing: $missing" >> "$REPORT_FILE"
      missing_section_count=$((missing_section_count + 1))
    fi
  done
fi

if [ $missing_section_count -eq 0 ]; then
  echo "All entries have the required sections." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $missing_section_count entries with missing sections**" >> "$REPORT_FILE"
  total_issues=$((total_issues + missing_section_count))
fi

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
echo "| Stale reviews | $stale_count |" >> "$REPORT_FILE"
echo "| Broken wikilinks | $broken_count |" >> "$REPORT_FILE"
echo "| Near-empty notes | $empty_count |" >> "$REPORT_FILE"
echo "| Concept structure issues | $conflict_count |" >> "$REPORT_FILE"
echo "| Orphaned concepts | $orphan_concept_count |" >> "$REPORT_FILE"
echo "| Wiki index drift | $drift_count |" >> "$REPORT_FILE"
echo "| Missing entry sections | $missing_section_count |" >> "$REPORT_FILE"
echo "| **TOTAL** | **$total_issues** |" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "*Run lint-vault.sh (v2) to regenerate this report.*" >> "$REPORT_FILE"

echo "Lint report (v2) written to $REPORT_FILE"
echo "Summary: $orphan_count orphaned, $stale_count stale reviews, $broken_count broken links, $empty_count near-empty, $total_issues total issues"
