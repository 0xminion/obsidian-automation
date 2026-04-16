#!/usr/bin/env bash
# ============================================================================
# v2.2: Lint Vault — Karpathy-style health checks on the wiki
# ============================================================================
# Changes from v2.1:
#   - Sources common library (lib/common.sh)
#   - Removed mandatory ELI5 section check (now template-aware)
#   - Added review status check (entries older than 7 days, unreviewed)
#   - Added edges.tsv consistency check
#   - Added entry template section validation (check 7)
#   - Git auto-commit after lint
#   - 10 health checks total
#
# Writes report to: $VAULT_PATH/Meta/Scripts/lint-report.md
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

REPORT_FILE="$VAULT_PATH/Meta/Scripts/lint-report.md"
REPORT_DATE=$(date +%Y-%m-%d)

mkdir -p "$VAULT_PATH/Meta/Scripts"

echo "# Lint Report — $REPORT_DATE (v2.4)" > "$REPORT_FILE"
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

    # Check entry_refs exist
    entry_refs=$(grep -A20 'entry_refs:' "$note" 2>/dev/null | grep -oE '\[\[.+?\]\]' | sed 's/\[\[//;s/\]\]//' || true)
    if [ -z "$entry_refs" ]; then
      echo "- **[$note_name]**: Concept has no Entry references — orphaned concept?" >> "$REPORT_FILE"
      conflict_count=$((conflict_count + 1))
    fi

    # Check bilingual template sections
    template=$(grep -m1 '^template:' "$note" 2>/dev/null | sed 's/^template: *//' | tr -d '[:space:]' || echo "")
    if [ "$template" = "bilingual" ]; then
      for section in "## Overview / 概述" "## Core Idea / 核心概念" "## How It Works / 运作机制" "## Why It Matters / 为什么重要" "## In Practice / 实际案例" "## Connections / 关联" "## Open Questions / 开放问题" "## References"; do
        if ! grep -qF "$section" "$note" 2>/dev/null; then
          echo "- **[$note_name]** (bilingual) missing: $section" >> "$REPORT_FILE"
          conflict_count=$((conflict_count + 1))
        fi
      done
      # Check each language section has both English and Chinese subsections
      for section in "Core Idea" "How It Works" "Why It Matters" "In Practice"; do
        has_en=$(grep -A5 "## $section" "$note" 2>/dev/null | grep -c "### English" || true)
        has_zh=$(grep -A5 "## $section" "$note" 2>/dev/null | grep -c "### 中文" || true)
        if [ "$has_en" -eq 0 ] || [ "$has_zh" -eq 0 ]; then
          echo "- **[$note_name]** (bilingual): '$section' missing ### English or ### 中文 subsection" >> "$REPORT_FILE"
          conflict_count=$((conflict_count + 1))
        fi
      done
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
# 7. Entry Template Section Validation (v2.4)
# ═══════════════════════════════════════════════════════════
echo "## 7. Entry Template Section Validation" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
template_issues=0

# Define required sections per template type
# Using arrays for portability
check_template_sections() {
  local entry_file="$1"
  local template="$2"
  local entry_name
  entry_name=$(basename "$entry_file" .md)
  local missing_sections=""

  case "$template" in
    standard|"")
      for section in "## Summary" "## ELI5 insights" "## Diagrams" "## Open questions" "## Linked concepts"; do
        if ! grep -qF "$section" "$entry_file" 2>/dev/null; then
          missing_sections="${missing_sections}    - ${section}\n"
        fi
      done
      ;;
    technical)
      for section in "## Summary" "## Key Findings" "## Data/Evidence" "## Methodology" "## Limitations" "## Linked concepts"; do
        if ! grep -qF "$section" "$entry_file" 2>/dev/null; then
          missing_sections="${missing_sections}    - ${section}\n"
        fi
      done
      ;;
    comparison)
      for section in "## Summary" "## Side-by-Side Comparison" "## Pros and Cons" "## Verdict" "## Linked concepts"; do
        if ! grep -qF "$section" "$entry_file" 2>/dev/null; then
          missing_sections="${missing_sections}    - ${section}\n"
        fi
      done
      ;;
    procedural)
      for section in "## Summary" "## Prerequisites" "## Steps" "## Gotchas" "## Linked concepts"; do
        if ! grep -qF "$section" "$entry_file" 2>/dev/null; then
          missing_sections="${missing_sections}    - ${section}\\n"
        fi
      done
      ;;
    chinese)
      for section in "## 摘要" "## 关键洞察" "### 核心发现" "### 其他要点" "## 图表" "## 开放问题" "## 关联概念"; do
        if ! grep -qF "$section" "$entry_file" 2>/dev/null; then
          missing_sections="${missing_sections}    - ${section}\\n"
        fi
      done
      ;;
    bilingual)
      for section in "## Summary / 摘要" "## Key Insights / 关键洞察" "## Diagrams / 图表" "## Open Questions / 开放问题" "## Linked Concepts / 关联概念"; do
        if ! grep -qF "$section" "$entry_file" 2>/dev/null; then
          missing_sections="${missing_sections}    - ${section}\\n"
        fi
      done
      ;;
  esac

  if [ -n "$missing_sections" ]; then
    echo "- **[$entry_name]** (template: $template) missing sections:" >> "$REPORT_FILE"
    printf "%b" "$missing_sections" >> "$REPORT_FILE"
    return 1
  fi
  return 0
}

if [ -d "$VAULT_PATH/04-Wiki/entries" ]; then
  for entry in "$VAULT_PATH/04-Wiki/entries"/*.md; do
    [ -f "$entry" ] || continue
    template=$(grep -m1 '^template:' "$entry" 2>/dev/null | sed 's/^template: *//' | tr -d '[:space:]' || echo "standard")
    [ -z "$template" ] && template="standard"

    if ! check_template_sections "$entry" "$template"; then
      template_issues=$((template_issues + 1))
    fi
  done
fi

if [ $template_issues -eq 0 ]; then
  echo "All entries have correct sections for their template type." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $template_issues entries with missing template sections**" >> "$REPORT_FILE"
  echo "Action: Add missing sections or change the template type." >> "$REPORT_FILE"
  total_issues=$((total_issues + template_issues))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 8. Orphaned Concepts (no Entry references them)
# ═══════════════════════════════════════════════════════════
echo "## 8. Orphaned Concepts (no Entry links to them)" >> "$REPORT_FILE"
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
# 9. Wiki Index Drift
# ═══════════════════════════════════════════════════════════
echo "## 9. Wiki Index Drift (index vs actual notes)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
drift_count=0

if [ -f "$VAULT_PATH/06-Config/wiki-index.md" ]; then
  index_entry_count=$(grep -c '(entry)' "$VAULT_PATH/06-Config/wiki-index.md" 2>/dev/null | tr -d ' \n' || echo 0)
  index_concept_count=$(grep -c '(concept)' "$VAULT_PATH/06-Config/wiki-index.md" 2>/dev/null | tr -d ' \n' || echo 0)

  actual_entry_count=$(find "$VAULT_PATH/04-Wiki/entries" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  actual_concept_count=$(find "$VAULT_PATH/04-Wiki/concepts" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

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
# 10. Edges Consistency Check (v2.4)
# ═══════════════════════════════════════════════════════════
echo "## 10. Edges Consistency (edges.tsv)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
edge_issues=0

if [ -f "$VAULT_PATH/06-Config/edges.tsv" ]; then
  total_edges=$(( $(wc -l < "$VAULT_PATH/06-Config/edges.tsv" | tr -d ' ') - 1 ))
  [ "$total_edges" -lt 0 ] 2>/dev/null && total_edges=0

  # Check for edges referencing non-existent notes
  # Format: source<tab>relation<tab>target (3 columns)
  while IFS=$'\t' read -r source relation target; do
    [ -z "$source" ] && continue
    [[ "$source" == "#"* ]] && continue  # Skip comments/headers

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
# 11. Stub/Placeholder Detection (v2.5)
# ═══════════════════════════════════════════════════════════
echo "## 11. Stub/Placeholder Detection" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
stub_count=0

# Expanded placeholder patterns — detect incomplete sections
STUB_PATTERNS="> 待补充|> 待分析|> 待深入研究|> 待深入|> TODO|> TBD|> FIXME|> PLACEHOLDER|> 待完善|> 待更新|> 待定|> 待处理"

for dir in "04-Wiki/entries" "04-Wiki/concepts"; do
  dir_path="$VAULT_PATH/$dir"
  [ -d "$dir_path" ] || continue

  for note in "$dir_path"/*.md; do
    [ -f "$note" ] || continue
    note_name=$(basename "$note" .md)
    note_rel="${note#$VAULT_PATH/}"

    # Find stub lines and report which section they're in
    while IFS= read -r stub_line; do
      [ -z "$stub_line" ] && continue
      # Find which ## section this stub is under
      line_num=$(grep -Fn "$stub_line" "$note" | head -1 | cut -d: -f1)
      section=$(head -n "$line_num" "$note" | grep -E '^## ' | tail -1 | sed 's/^## //')
      echo "- **[$note_name]** in section '$section': \`${stub_line:0:60}\`" >> "$REPORT_FILE"
      stub_count=$((stub_count + 1))
    done < <(grep -En "$STUB_PATTERNS" "$note" 2>/dev/null | sed 's/^[0-9]*://' || true)
  done
done

if [ $stub_count -eq 0 ]; then
  echo "No stubs or placeholders found." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $stub_count stub/placeholder sections found**" >> "$REPORT_FILE"
  echo "Action: Fill these sections with real content from sources. Never leave stubs." >> "$REPORT_FILE"
  total_issues=$((total_issues + stub_count))
fi

echo "" >> "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════
# 12. Tag Quality Validation (v2.5)
# ═══════════════════════════════════════════════════════════
echo "## 12. Tag Quality Validation" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
tag_issue_count=0

# Blocklist: platform URLs, generic link metadata — NOT topic tags
# Note: 'source' is valid on Source notes but not as the only tag on entries
# 'podcast', 'video', 'blog' are valid source_types
BLOCKED_TAGS="x\.com|tweet|http|https|rss|feed|url|link"

for dir in "04-Wiki/entries" "04-Wiki/sources" "04-Wiki/concepts"; do
  dir_path="$VAULT_PATH/$dir"
  [ -d "$dir_path" ] || continue

  for note in "$dir_path"/*.md; do
    [ -f "$note" ] || continue
    note_name=$(basename "$note" .md)

    # Extract tags from frontmatter
    in_tags=false
    while IFS= read -r line; do
      if [[ "$line" =~ ^tags: ]]; then
        in_tags=true
        continue
      fi
      if $in_tags; then
        if [[ ! "$line" =~ ^[[:space:]]+- ]]; then
          in_tags=false
          continue
        fi
        tag=$(echo "$line" | sed 's/^[[:space:]]*- //' | tr -d '[:space:]')
        if echo "$tag" | grep -qiE "^($BLOCKED_TAGS)$"; then
          echo "- **[$note_name]**: blocked tag '$tag'" >> "$REPORT_FILE"
          tag_issue_count=$((tag_issue_count + 1))
        fi
        # Also flag single-char or empty tags
        if [ ${#tag} -le 1 ]; then
          echo "- **[$note_name]**: too-short tag '$tag'" >> "$REPORT_FILE"
          tag_issue_count=$((tag_issue_count + 1))
        fi
      fi
    done < "$note"
  done
done

if [ $tag_issue_count -eq 0 ]; then
  echo "All tags pass quality checks." >> "$REPORT_FILE"
else
  echo "" >> "$REPORT_FILE"
  echo "**Total: $tag_issue_count invalid tags found**" >> "$REPORT_FILE"
  echo "Action: Replace with topic-specific tags. Tags must describe the content, not the platform." >> "$REPORT_FILE"
  total_issues=$((total_issues + tag_issue_count))
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
echo "| Unreviewed entries | $unreviewed_count |" >> "$REPORT_FILE"
echo "| Stale reviews | $stale_count |" >> "$REPORT_FILE"
echo "| Broken wikilinks | $broken_count |" >> "$REPORT_FILE"
echo "| Near-empty notes | $empty_count |" >> "$REPORT_FILE"
echo "| Concept structure issues | $conflict_count |" >> "$REPORT_FILE"
echo "| Template section issues | $template_issues |" >> "$REPORT_FILE"
echo "| Orphaned concepts | $orphan_concept_count |" >> "$REPORT_FILE"
echo "| Wiki index drift | $drift_count |" >> "$REPORT_FILE"
echo "| Edges consistency | $edge_issues |" >> "$REPORT_FILE"
echo "| Stub/placeholder sections | $stub_count |" >> "$REPORT_FILE"
echo "| Invalid tags | $tag_issue_count |" >> "$REPORT_FILE"
echo "| **TOTAL** | **$total_issues** |" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "*Run lint-vault.sh (v2.4) to regenerate this report.*" >> "$REPORT_FILE"

# Log entry
append_log_md "lint" "Health check" \
  "- Orphaned notes: $orphan_count
- Unreviewed entries: $unreviewed_count
- Stale reviews: $stale_count
- Broken wikilinks: $broken_count
- Near-empty notes: $empty_count
- Concept structure issues: $conflict_count
- Template section issues: $template_issues
- Orphaned concepts: $orphan_concept_count
- Wiki index drift: $drift_count
- Edges consistency: $edge_issues
- Stub/placeholder sections: $stub_count
- Invalid tags: $tag_issue_count
- Total issues: $total_issues
- Full report: Meta/Scripts/lint-report.md"

auto_commit "lint" "Health check ($total_issues total issues)"

echo "Lint report written to $REPORT_FILE"
echo "Summary: $orphan_count orphaned, $unreviewed_count unreviewed, $stale_count stale, $broken_count broken links, $total_issues total issues"
