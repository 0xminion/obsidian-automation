#!/usr/bin/env bash
# ============================================================================
# v2.1.0: Update Tag Registry — Rebuild tag-registry.md from actual usage
# ============================================================================
# Scans all entries and concepts, extracts tags, and rebuilds the registry.
# Run manually or via cron to keep tag-registry.md in sync with actual usage.
#
# Usage: VAULT_PATH="$HOME/MyVault" bash update-tag-registry.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

acquire_lock "update-tag-registry" || exit 1

TAG_REGISTRY="$VAULT_PATH/06-Config/tag-registry.md"
REPORT_DATE=$(date +%Y-%m-%d)

log "=== Starting tag registry update ==="

# Temporary files for tag collection
ENTRY_TAGS_TMP=$(mktemp)
CONCEPT_TAGS_TMP=$(mktemp)
trap 'rm -f "$ENTRY_TAGS_TMP" "$CONCEPT_TAGS_TMP"' EXIT

# Extract tags from entries (handles both inline and multi-line YAML)
echo "# Tag Registry" > "$TAG_REGISTRY"
echo "" >> "$TAG_REGISTRY"
echo "Canonical list of tags used in this wiki. Before minting a new tag," >> "$TAG_REGISTRY"
echo "check this registry and prefer reuse." >> "$TAG_REGISTRY"
echo "" >> "$TAG_REGISTRY"
echo "Auto-updated on $REPORT_DATE" >> "$TAG_REGISTRY"
echo "" >> "$TAG_REGISTRY"

extract_yaml_tags() {
  local file="$1"
  python3 -c "
import re, sys
with open('$file') as f:
    content = f.read()
# Extract frontmatter
m = re.search(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if not m:
    sys.exit(0)
fm = m.group(1)
# Find tags block
m2 = re.search(r'^tags:\s*\n((?:\s+-\s+.+\n?)+)', fm, re.MULTILINE)
if m2:
    for line in m2.group(1).strip().split('\n'):
        tag = re.sub(r'^\s*-\s*', '', line).strip().strip('\"')
        if tag:
            print(tag)
else:
    # Inline format: tags: [a, b, c] or tags: a b c
    m3 = re.search(r'^tags:\s*\[(.+?)\]', fm, re.MULTILINE)
    if m3:
        for tag in m3.group(1).split(','):
            tag = tag.strip().strip('\"')
            if tag:
                print(tag)
    else:
        m4 = re.search(r'^tags:\s*(.+)', fm, re.MULTILINE)
        if m4:
            for tag in m4.group(1).split():
                tag = tag.strip().strip('\"')
                if tag:
                    print(tag)
" 2>/dev/null
}

# Collect entry tags
if [ -d "$VAULT_PATH/04-Wiki/entries" ]; then
  for entry in "$VAULT_PATH/04-Wiki/entries"/*.md; do
    [ -f "$entry" ] || continue
    extract_yaml_tags "$entry" >> "$ENTRY_TAGS_TMP"
  done
  
  # Count and sort entry tags
  if [ -s "$ENTRY_TAGS_TMP" ]; then
    echo "## Entry Tags" >> "$TAG_REGISTRY"
    echo "" >> "$TAG_REGISTRY"
    sort "$ENTRY_TAGS_TMP" | uniq -c | sort -rn | while read count tag; do
      echo "- \`$tag\` ($count uses)" >> "$TAG_REGISTRY"
    done
    echo "" >> "$TAG_REGISTRY"
  fi
fi

# Collect concept tags
if [ -d "$VAULT_PATH/04-Wiki/concepts" ]; then
  for concept in "$VAULT_PATH/04-Wiki/concepts"/*.md; do
    [ -f "$concept" ] || continue
    extract_yaml_tags "$concept" >> "$CONCEPT_TAGS_TMP"
  done
  
  # Count and sort concept tags
  if [ -s "$CONCEPT_TAGS_TMP" ]; then
    echo "## Concept Tags" >> "$TAG_REGISTRY"
    echo "" >> "$TAG_REGISTRY"
    sort "$CONCEPT_TAGS_TMP" | uniq -c | sort -rn | while read count tag; do
      echo "- \`$tag\` ($count uses)" >> "$TAG_REGISTRY"
    done
    echo "" >> "$TAG_REGISTRY"
  fi
fi

# Add MoC tags if any
if [ -d "$VAULT_PATH/04-Wiki/mocs" ]; then
  moc_tag_count=0
  echo "## MoC Tags" >> "$TAG_REGISTRY"
  echo "" >> "$TAG_REGISTRY"
  moc_tags_tmp=$(mktemp)
  for moc in "$VAULT_PATH/04-Wiki/mocs"/*.md; do
    [ -f "$moc" ] || continue
    extract_yaml_tags "$moc" >> "$moc_tags_tmp"
  done
  if [ -s "$moc_tags_tmp" ]; then
    sort "$moc_tags_tmp" | uniq -c | sort -rn | while read count tag; do
      echo "- \`$tag\` ($count uses)" >> "$TAG_REGISTRY"
    done
    moc_tag_count=$(wc -l < "$moc_tags_tmp" | tr -d ' ')
  else
    echo "- (no MoC tags found)" >> "$TAG_REGISTRY"
  fi
  rm -f "$moc_tags_tmp"
  echo "" >> "$TAG_REGISTRY"
fi

# Summary
entry_tag_count=$(sort "$ENTRY_TAGS_TMP" 2>/dev/null | uniq -c | wc -l | tr -d ' ' || echo 0)
concept_tag_count=$(sort "$CONCEPT_TAGS_TMP" 2>/dev/null | uniq -c | wc -l | tr -d ' ' || echo 0)

echo "---" >> "$TAG_REGISTRY"
echo "" >> "$TAG_REGISTRY"
echo "*Updated on $REPORT_DATE: $entry_tag_count entry tags, $concept_tag_count concept tags*" >> "$TAG_REGISTRY"

log "Tag registry updated: $entry_tag_count entry tags, $concept_tag_count concept tags"

append_log_md "tag-registry" "Tag registry rebuild" \
  "- Entry tags: $entry_tag_count
- Concept tags: $concept_tag_count
- Output: 06-Config/tag-registry.md"

auto_commit "tag-registry" "Tag registry update ($entry_tag_count entry, $concept_tag_count concept tags)"

echo "Tag registry updated: $entry_tag_count entry tags, $concept_tag_count concept tags"
echo "Written to $TAG_REGISTRY"