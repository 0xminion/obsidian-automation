#!/usr/bin/env bash
# ============================================================================
# Migrate Vault — Adopt existing Obsidian vault into v2 structure
# ============================================================================
# Optional tool for migrating existing vaults into the obsidian-automation
# format. Does NOT run automatically — must be explicitly invoked.
#
# Usage:
#   bash migrate-vault.sh --scan              # Audit only, no changes
#   bash migrate-vault.sh --dry-run           # Show what would change
#   bash migrate-vault.sh --execute           # Make changes (with backup)
#   bash migrate-vault.sh --execute --no-backup  # Skip backup (not recommended)
#
# Requires: VAULT_PATH set to your existing vault root
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ═══════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════
MODE=""
NO_BACKUP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan)      MODE="scan"; shift ;;
    --dry-run)   MODE="dry-run"; shift ;;
    --execute)   MODE="execute"; shift ;;
    --no-backup) NO_BACKUP=true; shift ;;
    -h|--help)
      echo "Usage: migrate-vault.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --scan        Audit vault: report missing fields, collisions, format issues"
      echo "  --dry-run     Show exactly what changes would be made"
      echo "  --execute     Apply changes (creates backup by default)"
      echo "  --no-backup   Skip backup creation (use with --execute)"
      echo ""
      echo "Environment:"
      echo "  VAULT_PATH    Path to your Obsidian vault (default: ~/MyVault)"
      echo ""
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Error: No mode specified. Use --scan, --dry-run, or --execute."
  echo "Run with --help for usage."
  exit 1
fi

# ═══════════════════════════════════════════════════════════
# REPORTING
# ═══════════════════════════════════════════════════════════
REPORT_FILE="$VAULT_PATH/migration-report-$(date +%Y%m%d-%H%M%S).md"

total_notes=0
notes_missing_frontmatter=0
notes_missing_reviewed=0
notes_missing_template=0
notes_missing_review_notes=0
notes_missing_aliases=0
filename_collisions=0
notes_fixed=0

report() {
  echo "$1"
  echo "$1" >> "$REPORT_FILE"
}

# ═══════════════════════════════════════════════════════════
# FRONTMATTER DETECTION
# ═══════════════════════════════════════════════════════════
has_frontmatter() {
  local file="$1"
  head -1 "$file" 2>/dev/null | grep -q '^---$'
}

has_field() {
  local file="$1"
  local field="$2"
  grep -q "^${field}:" "$file" 2>/dev/null
}

is_entry_note() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  # In entries/ directory, or has entry-like frontmatter
  [[ "$dir" == */entries ]] || \
  (has_frontmatter "$file" && grep -q '^status: review$\|^status: evergreen$\|^status: seed$' "$file" 2>/dev/null && \
   grep -q '^source:' "$file" 2>/dev/null)
}

is_concept_note() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  [[ "$dir" == */concepts ]] || \
  (has_frontmatter "$file" && grep -q '^\s*- "[\[' "$file" 2>/dev/null && \
   grep -q '^entry_refs:' "$file" 2>/dev/null)
}

is_moc_note() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  [[ "$dir" == */mocs ]] || \
  (has_frontmatter "$file" && grep -q '^type: moc$' "$file" 2>/dev/null)
}

# ═══════════════════════════════════════════════════════════
# SCAN: Audit existing vault
# ═══════════════════════════════════════════════════════════
scan_vault() {
  report "# Migration Scan Report — $(date +%Y-%m-%d)"
  report ""
  report "Vault: $VAULT_PATH"
  report "Mode: scan (read-only)"
  report ""
  report "---"
  report ""

  # Find all .md files in wiki directories (not config, not archive, not WIP)
  local scan_dirs=()
  for dir in "04-Wiki/entries" "04-Wiki/concepts" "04-Wiki/mocs" "04-Wiki/sources" \
             "entries" "concepts" "mocs" "sources" "notes" "wiki"; do
    [ -d "$VAULT_PATH/$dir" ] && scan_dirs+=("$VAULT_PATH/$dir")
  done

  # Also scan root-level .md files that might be notes
  if [ ${#scan_dirs[@]} -eq 0 ]; then
    report "## No standard wiki directories found"
    report ""
    report "Searched for: 04-Wiki/entries, entries/, notes/, wiki/"
    report ""
    report "Your vault structure may be non-standard. Scanning all .md files..."
    report ""
    scan_dirs=("$VAULT_PATH")
  fi

  report "## Directories Scanned"
  report ""
  for d in "${scan_dirs[@]}"; do
    report "- $d"
  done
  report ""

  # Scan each .md file
  report "## Note Analysis"
  report ""
  report "| Issue | Count |"
  report "|-------|-------|"

  local missing_fm=0
  local missing_reviewed=0
  local missing_template=0
  local missing_review_notes=0
  local missing_aliases=0
  local total=0

  for scan_dir in "${scan_dirs[@]}"; do
    while IFS= read -r -d '' note; do
      # Skip non-note files (README, CHANGELOG, etc.)
      local basename_note
      basename_note=$(basename "$note")
      [[ "$basename_note" =~ ^(README|CHANGELOG|LICENSE|CODE_REVIEW|PRD)\.md$ ]] && continue

      # Skip v1/, .git/, 06-Config/, 08-Archive, 09-Archive
      [[ "$note" == */v1/* ]] && continue
      [[ "$note" == */.git/* ]] && continue
      [[ "$note" == */06-Config/* ]] && continue
      [[ "$note" == */08-Archive*/* ]] && continue
      [[ "$note" == */09-Archive*/* ]] && continue
      [[ "$note" == */Meta/* ]] && continue

      total=$((total + 1))

      if ! has_frontmatter "$note"; then
        missing_fm=$((missing_fm + 1))
        if [ "$MODE" = "scan" ]; then
          report "- **No frontmatter**: $(basename "$note")"
        fi
        continue
      fi

      # Check required fields for entry notes
      if is_entry_note "$note"; then
        if ! has_field "$note" "reviewed"; then
          missing_reviewed=$((missing_reviewed + 1))
        fi
        if ! has_field "$note" "template"; then
          missing_template=$((missing_template + 1))
        fi
        if ! has_field "$note" "review_notes"; then
          missing_review_notes=$((missing_review_notes + 1))
        fi
        if ! has_field "$note" "aliases"; then
          missing_aliases=$((missing_aliases + 1))
        fi
      fi
    done < <(find "$scan_dir" -name '*.md' -type f -print0 2>/dev/null)
  done

  report "| Notes scanned | $total |"
  report "| Missing frontmatter entirely | $missing_fm |"
  report "| Missing \`reviewed:\` field (entries) | $missing_reviewed |"
  report "| Missing \`template:\` field (entries) | $missing_template |"
  report "| Missing \`review_notes:\` field (entries) | $missing_review_notes |"
  report "| Missing \`aliases:\` field (entries) | $missing_aliases |"
  report ""

  total_notes=$total
  notes_missing_frontmatter=$missing_fm
  notes_missing_reviewed=$missing_reviewed
  notes_missing_template=$missing_template
  notes_missing_review_notes=$missing_review_notes
  notes_missing_aliases=$missing_aliases

  # Check directory structure
  report "## Directory Structure"
  report ""
  local expected_dirs=("01-Raw" "02-Clippings" "03-Queries" "04-Wiki/entries" \
    "04-Wiki/concepts" "04-Wiki/mocs" "04-Wiki/sources" "05-Outputs" \
    "06-Config" "07-WIP" "08-Archive-Raw" "09-Archive-Queries")
  local missing_dirs=0
  for dir in "${expected_dirs[@]}"; do
    if [ ! -d "$VAULT_PATH/$dir" ]; then
      report "- **Missing**: $dir/"
      missing_dirs=$((missing_dirs + 1))
    else
      report "- OK: $dir/"
    fi
  done
  report ""
  report "Missing directories: $missing_dirs (will be created by setup_directory_structure)"
  report ""

  report "## Summary"
  report ""
  if [ $missing_fm -gt 0 ] || [ $missing_reviewed -gt 0 ] || [ $missing_template -gt 0 ]; then
    report "Issues found. Run \`--dry-run\` to preview fixes, then \`--execute\` to apply."
  else
    report "No issues found. Vault is compatible with v2 structure."
  fi
}

# ═══════════════════════════════════════════════════════════
# DRY RUN / EXECUTE: Fix missing fields
# ═══════════════════════════════════════════════════════════
fix_vault() {
  local action="$1"  # "dry-run" or "execute"

  report "# Migration $action Report — $(date +%Y-%m-%d)"
  report ""
  report "Vault: $VAULT_PATH"
  report ""

  if [ "$action" = "execute" ] && [ "$NO_BACKUP" = false ]; then
    local backup_file="$VAULT_PATH/migration-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    report "Creating backup: $backup_file"
    echo "Creating backup: $backup_file"
    tar -czf "$backup_file" \
      -C "$VAULT_PATH" \
      --exclude='.git' \
      --exclude='v1' \
      04-Wiki 06-Config 2>/dev/null || true
    report "Backup created."
    report ""
  fi

  report "---"
  report ""

  # Step 1: Ensure directory structure exists
  if [ "$action" = "execute" ]; then
    setup_directory_structure
  fi
  report "## Step 1: Directory Structure"
  report "Ensured all 01-09 directories exist. (non-destructive)"
  report ""

  # Step 2: Fix entry notes missing frontmatter fields
  report "## Step 2: Entry Notes — Missing Fields"
  report ""

  local fixed_count=0
  local checked_count=0

  for dir in "04-Wiki/entries" "04-Wiki/concepts" "04-Wiki/mocs"; do
    local dir_path="$VAULT_PATH/$dir"
    [ -d "$dir_path" ] || continue

    while IFS= read -r -d '' note; do
      checked_count=$((checked_count + 1))
      local basename_note
      basename_note=$(basename "$note")
      local changes_needed=false
      local changes=""

      # Skip files without frontmatter — those need manual attention
      if ! has_frontmatter "$note"; then
        report "- **SKIP** (no frontmatter): $basename_note — needs manual review"
        continue
      fi

      # Add reviewed: null if missing (entries only)
      if is_entry_note "$note" && ! has_field "$note" "reviewed"; then
        changes_needed=true
        changes="${changes}  + Add reviewed: null\n"
        if [ "$action" = "execute" ]; then
          # Insert after status: line, or after first --- if no status
          if has_field "$note" "status"; then
            sed -i '/^status:/a reviewed: null' "$note" 2>/dev/null || \
            sed -i '' '/^status:/a\
reviewed: null' "$note" 2>/dev/null || true
          elif has_field "$note" "tags"; then
            sed -i '/^tags:/i reviewed: null' "$note" 2>/dev/null || \
            sed -i '' '/^tags:/i\
reviewed: null' "$note" 2>/dev/null || true
          else
            # Insert after opening ---
            sed -i '0,/^---$/!{0,/^---$/s/^---$/reviewed: null\n---/}' "$note" 2>/dev/null || true
          fi
        fi
      fi

      # Add review_notes: null if missing (entries only)
      if is_entry_note "$note" && ! has_field "$note" "review_notes"; then
        changes_needed=true
        changes="${changes}  + Add review_notes: null\n"
        if [ "$action" = "execute" ]; then
          if has_field "$note" "reviewed"; then
            sed -i '/^reviewed:/a review_notes: null' "$note" 2>/dev/null || \
            sed -i '' '/^reviewed:/a\
review_notes: null' "$note" 2>/dev/null || true
          fi
        fi
      fi

      # Add template: standard if missing (entries only)
      if is_entry_note "$note" && ! has_field "$note" "template"; then
        changes_needed=true
        changes="${changes}  + Add template: standard\n"
        if [ "$action" = "execute" ]; then
          if has_field "$note" "review_notes"; then
            sed -i '/^review_notes:/a template: standard' "$note" 2>/dev/null || \
            sed -i '' '/^review_notes:/a\
template: standard' "$note" 2>/dev/null || true
          elif has_field "$note" "reviewed"; then
            sed -i '/^reviewed:/a template: standard' "$note" 2>/dev/null || \
            sed -i '' '/^reviewed:/a\
template: standard' "$note" 2>/dev/null || true
          fi
        fi
      fi

      # Add aliases: [] if missing
      if (is_entry_note "$note" || is_concept_note "$note") && ! has_field "$note" "aliases"; then
        changes_needed=true
        changes="${changes}  + Add aliases: []\n"
        if [ "$action" = "execute" ]; then
          # Insert before closing ---
          sed -i '/^---$/i aliases: []' "$note" 2>/dev/null || \
          sed -i '' '/^---$/i\
aliases: []' "$note" 2>/dev/null || true
        fi
      fi

      if $changes_needed; then
        fixed_count=$((fixed_count + 1))
        if [ "$action" = "dry-run" ]; then
          report "- **WOULD FIX**: $basename_note"
          printf "%b" "$changes" | while read -r line; do report "  $line"; done
        else
          report "- **FIXED**: $basename_note"
          printf "%b" "$changes" | while read -r line; do report "  $line"; done
        fi
      fi
    done < <(find "$dir_path" -name '*.md' -type f -print0 2>/dev/null)
  done

  report ""
  report "Checked: $checked_count notes"
  if [ "$action" = "dry-run" ]; then
    report "Would fix: $fixed_count notes"
  else
    report "Fixed: $fixed_count notes"
    notes_fixed=$fixed_count
  fi
  report ""

  # Step 3: Initialize url-index.tsv if missing
  report "## Step 3: URL Index"
  if [ ! -f "$VAULT_PATH/06-Config/url-index.tsv" ]; then
    if [ "$action" = "execute" ]; then
      bootstrap_url_index
      report "Built url-index.tsv from existing sources."
    else
      report "Would build url-index.tsv from existing sources."
    fi
  else
    report "url-index.tsv exists — skipping."
  fi
  report ""

  # Step 4: Initialize edges.tsv if missing
  report "## Step 4: Edges File"
  if [ ! -f "$VAULT_PATH/06-Config/edges.tsv" ]; then
    if [ "$action" = "execute" ]; then
      mkdir -p "$VAULT_PATH/06-Config"
      printf "source\ttarget\ttype\tdescription\n" > "$VAULT_PATH/06-Config/edges.tsv"
      report "Created edges.tsv."
    else
      report "Would create edges.tsv."
    fi
  else
    report "edges.tsv exists — skipping."
  fi
  report ""

  report "## Summary"
  report ""
  if [ "$action" = "dry-run" ]; then
    report "This was a dry-run. No files were modified."
    report "Run \`--execute\` to apply these changes."
  else
    report "Migration complete."
    report "Notes fixed: $notes_fixed"
    if [ "$NO_BACKUP" = false ]; then
      report "Backup: $backup_file"
    fi
    report ""
    report "Next steps:"
    report "1. Run \`lint-vault.sh\` to check remaining issues"
    report "2. Run \`reindex.sh\` to rebuild wiki-index.md"
    report "3. Review notes without frontmatter manually"
  fi
}

# ═══════════════════════════════════════════════════════════
# COLLISION DETECTION (provided by common.sh)
# ═══════════════════════════════════════════════════════════
# check_collision() and resolve_collision() are in lib/common.sh
# and available here since we source it above.

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Obsidian Automation — Vault Migration ==="
echo "Vault: $VAULT_PATH"
echo "Mode: $MODE"
echo ""

# Validate vault path
if [ ! -d "$VAULT_PATH" ]; then
  echo "Error: VAULT_PATH directory does not exist: $VAULT_PATH"
  exit 1
fi

case "$MODE" in
  scan)
    scan_vault
    ;;
  dry-run)
    fix_vault "dry-run"
    ;;
  execute)
    fix_vault "execute"
    ;;
esac

echo ""
echo "Report saved to: $REPORT_FILE"
echo "=== Done ==="
