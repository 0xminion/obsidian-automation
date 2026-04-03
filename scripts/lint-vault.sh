#!/usr/bin/env bash
# ============================================================================
# Lint Vault — Health checks on the wiki
# ============================================================================
# Inspired by Karpathy's "Linting" concept. Runs non-LLM checks to find:
# 1. Orphaned notes (no backlinks from other notes)
# 2. Stale frontmatter (status: review older than N days)
# 3. Broken wikilinks (links to notes that don't exist)
# 4. Inconsistent tagging (tags that don't match frontmatter vs body)
# 5. Empty or near-empty notes
#
# Writes a report to Meta/Scripts/lint-report.md
# ============================================================================

set -uo pipefail

VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
REPORT_FILE="$VAULT_PATH/Meta/Scripts/lint-report.md"
REPORT_DATE=$(date +%Y-%m-%d)

mkdir -p "$VAULT_PATH/Meta/Scripts"

echo "# Lint Report — $REPORT_DATE" > "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# ─────────────────────────────────────────────────────────
# 1. Orphaned Notes: files with zero incoming wikilinks
# ─────────────────────────────────────────────────────────
echo "## Orphaned Notes (no incoming wikilinks)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
orphan_count=0

for dir in "02-Distilled" "03-Atomic" "04-MoCs"; do
  dir_path="$VAULT_PATH/$dir"
  [ -d "$dir_path" ] || continue

  for note in "$dir_path"/*.md; do
    [ -f "$note" ] || continue
    note_name=$(basename "$note" .md)

    # Search for wikilinks to this note in all vault files
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
  echo "Consider: Create backlinks, add to an MoC, or archive if obsolete." >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"

# ─────────────────────────────────────────────────────────
# 2. Stale Reviews: status: review older than 14 days
# ─────────────────────────────────────────────────────────
echo "## Stale Reviews (status: review, >14 days old)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
stale_count=0
cutoff_date=$(date -d "14 days ago" +%Y-%m-%d 2>/dev/null || date -v-14d +%Y-%m-%d 2>/dev/null || echo "")

if [ -n "$cutoff_date" ]; then
  for dir in "02-Distilled" "03-Atomic"; do
    dir_path="$VAULT_PATH/$dir"
    [ -d "$dir_path" ] || continue

    for note in "$dir_path"/*.md; do
      [ -f "$note" ] || continue
      note_date=$(grep -m1 'date_distilled:' "$note" 2>/dev/null | sed 's/.*date_distilled: *//' | tr -d '[:space:]' || true)
      note_status=$(grep -m1 'status:' "$note" 2>/dev/null | sed 's/.*status: *//' | tr -d '[:space:]' || true)

      if [ "$note_status" = "review" ] && [ -n "$note_date" ] && [[ "$note_date" < "$cutoff_date" ]]; then
        note_name=$(basename "$note" .md)
        echo "- [$note_name]($dir/$note_name.md) — reviewed: $note_date" >> "$REPORT_FILE"
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
fi

echo "" >> "$REPORT_FILE"

# ─────────────────────────────────────────────────────────
# 3. Broken Wikilinks: links to notes that don't exist
# ─────────────────────────────────────────────────────────
echo "## Broken Wikilinks (link targets that don't exist)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
broken_count=0

# Extract all wikilinks from the vault
all_links=$(grep -roF '\[\[' "$VAULT_PATH" --include="*.md" \
  --exclude-dir=.git 2>/dev/null | wc -l)

if [ "$all_links" -gt 0 ]; then
  for dir in "02-Distilled" "03-Atomic" "01-Sources" "04-MoCs"; do
    dir_path="$VAULT_PATH/$dir"
    [ -d "$dir_path" ] || continue

    for note in "$dir_path"/*.md; do
      [ -f "$note" ] || continue
      note_rel="${note#$VAULT_PATH/}"

      # Extract wikilink targets from this note
      grep -oE '\[\[.+?\]\]' "$note" 2>/dev/null | sed 's/\[\[//;s/\]\]//' | while read -r link_target; do
        # Clean the link (strip #Headings and |Display Text)
        clean_target=$(echo "$link_target" | sed 's/[#|].*//' | tr -d '[:space:]')
        [ -z "$clean_target" ] && continue

        # Check if target file exists
        target_file=$(find "$VAULT_PATH" -name "${clean_target}.md" -not -path "*/.git/*" 2>/dev/null | head -1)
        if [ -z "$target_file" ]; then
          echo "- In [$note_rel](): -> [[$link_target]]" >> "$REPORT_FILE"
          broken_count=$((broken_count + 1))
        fi
      done
    done
  done
fi

if [ $broken_count -eq 0 ]; then
  echo "No broken wikilinks found." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $broken_count broken links**" >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"

# ─────────────────────────────────────────────────────────
# 4. Empty or Near-Empty Notes (< 50 characters body)
# ─────────────────────────────────────────────────────────
echo "## Empty or Near-Empty Notes (< 50 chars body)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
empty_count=0

for dir in "01-Sources" "02-Distilled" "03-Atomic" "04-MoCs"; do
  dir_path="$VAULT_PATH/$dir"
  [ -d "$dir_path" ] || continue

  for note in "$dir_path"/*.md; do
    [ -f "$note" ] || continue
    # Count non-frontmatter, non-whitespace characters
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
  echo "Consider: Delete or expand these notes." >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "---" >> "$REPORT_FILE"
echo "*Run lint-vault.sh to regenerate.*" >> "$REPORT_FILE"

echo "Lint report written to $REPORT_FILE"
echo "Summary: $orphan_count orphaned, $stale_count stale reviews, $broken_count broken links, $empty_count near-empty notes"
