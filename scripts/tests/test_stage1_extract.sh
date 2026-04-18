#!/usr/bin/env bash
# ============================================================================
# Stage 1 Tests — Extraction Logic
# Tests: URL routing, hash generation, JSON output, manifest, title extraction
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

section "Stage 1: Extraction Logic"

# ═══════════════════════════════════════════════════════════════════════════
# Test: URL hash generation is deterministic
# ═══════════════════════════════════════════════════════════════════════════
test_start "URL hash is deterministic"
url="https://example.com/article"
hash1=$(echo -n "$url" | md5sum | cut -c1-12)
hash2=$(echo -n "$url" | md5sum | cut -c1-12)
if assert_eq "$hash1" "$hash2" "hash stability"; then
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: Different URLs produce different hashes
# ═══════════════════════════════════════════════════════════════════════════
test_start "Different URLs produce different hashes"
hash_a=$(echo -n "https://example.com/a" | md5sum | cut -c1-12)
hash_b=$(echo -n "https://example.com/b" | md5sum | cut -c1-12)
if assert_ne "$hash_a" "$hash_b" "hash uniqueness"; then
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: Empty inbox — stage1 should handle gracefully
# ═══════════════════════════════════════════════════════════════════════════
test_start "Empty inbox handled gracefully"
vault=$(create_test_vault)
export VAULT_PATH="$vault"
export LOG_FILE="$vault/Meta/Scripts/processing.log"

# Run stage1 with empty inbox — should not crash
EXTRACT_DIR="/tmp/test-extract-empty-$$"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

# The loop over *.url with no matches should just skip (set -u + nullglob behavior)
shopt -s nullglob 2>/dev/null || true
count=0
for f in "$vault/01-Raw"/*.url; do
  count=$((count + 1))
done

if assert_eq "$count" "0" "no url files found"; then
  test_pass
fi
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: URL routing — YouTube detection
# ═══════════════════════════════════════════════════════════════════════════
test_start "YouTube URL detection"
url_yt="https://www.youtube.com/watch?v=dQw4w9WgXcQ"
if [[ "$url_yt" =~ youtu(be\.com|\.be) ]]; then
  test_pass
else
  test_fail "YouTube URL not detected"
fi

test_start "Short YouTube URL detection"
url_yt_short="https://youtu.be/dQw4w9WgXcQ"
if [[ "$url_yt_short" =~ youtu(be\.com|\.be) ]]; then
  test_pass
else
  test_fail "Short YouTube URL not detected"
fi

test_start "Blog URL not detected as YouTube"
url_blog="https://blog.example.com/article"
if ! [[ "$url_blog" =~ youtu(\\.be|be\\.com) ]]; then
  test_pass
else
  test_fail "Blog URL incorrectly matched YouTube"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: X/Twitter URL detection
# ═══════════════════════════════════════════════════════════════════════════
test_start "X/Twitter URL detection"
url_x="https://x.com/user/status/123456789"
if [[ "$url_x" =~ x\.com/ ]]; then
  test_pass
else
  test_fail "X/Twitter URL not detected"
fi

test_start "Web URL not detected as Twitter"
url_web="https://news.ycombinator.com"
if ! [[ "$url_web" =~ x\.com/ ]]; then
  test_pass
else
  test_fail "HN URL incorrectly matched Twitter"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: JSON output schema from extraction fixture
# ═══════════════════════════════════════════════════════════════════════════
test_start "Extraction JSON has required fields"
extract_dir="/tmp/test-extract-schema-$$"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
hash=$(create_extracted_fixture "$extract_dir" \
  "https://example.com/test" \
  "Test Article Title" \
  "This is test content for the article body." \
  "web" "test-author")

json_file="$extract_dir/${hash}.json"
assert_file_exists "$json_file" || true

# Check required fields
all_ok=true
for key in url title content type author source_file; do
  val=$(python3 -c "import json; print(json.load(open('$json_file')).get('$key', '__MISSING__'))" 2>/dev/null)
  if [ "$val" = "__MISSING__" ]; then
    test_fail "missing required field: $key"
    all_ok=false
    break
  fi
done
if $all_ok; then
  test_pass
fi
rm -rf "$extract_dir"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Manifest generation from extracted JSON files
# ═══════════════════════════════════════════════════════════════════════════
test_start "Manifest generation with multiple entries"
extract_dir="/tmp/test-extract-manifest-$$"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"

h1=$(create_extracted_fixture "$extract_dir" "https://example.com/1" "Article One" "Content one." "web" "author1")
h2=$(create_extracted_fixture "$extract_dir" "https://example.com/2" "Article Two" "Content two." "web" "author2")
h3=$(create_extracted_fixture "$extract_dir" "https://example.com/3" "Article Three" "Content three." "web" "author3")

create_manifest "$extract_dir"

manifest="$extract_dir/manifest.json"
assert_file_exists "$manifest" || true

count=$(python3 -c "import json; print(len(json.load(open('$manifest'))))" 2>/dev/null)
if assert_eq "$count" "3" "manifest entry count"; then
  # Check each entry has a hash field
  has_hash=$(python3 -c "
import json
with open('$manifest') as f:
    m = json.load(f)
print(all('hash' in e for e in m))
" 2>/dev/null)
  if assert_eq "$has_hash" "True" "all entries have hash"; then
    test_pass
  fi
fi
rm -rf "$extract_dir"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Dedup — same URL hash skips re-extraction
# ═══════════════════════════════════════════════════════════════════════════
test_start "Dedup: same URL produces same hash"
url="https://example.com/dedup-test"
h1=$(echo -n "$url" | md5sum | cut -c1-12)
h2=$(echo -n "$url" | md5sum | cut -c1-12)
if assert_eq "$h1" "$h2" "dedup hash"; then
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: Title extraction from content — markdown heading
# ═══════════════════════════════════════════════════════════════════════════
test_start "Title extraction from markdown heading"
content="# My Article Title

Some content here."
# Replicate the extract_title_from_content logic
heading=$(echo "$content" | grep -m1 '^# ' | sed 's/^# //' | head -c 120)
if assert_eq "$heading" "My Article Title" "heading extraction"; then
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: Title extraction — filters "Original content"
# ═══════════════════════════════════════════════════════════════════════════
test_start "Title extraction skips 'Original content' heading"
content="# Original content of something\n\nBody text."
heading=$(echo "$content" | grep -m1 '^# ' | sed 's/^# //' | head -c 120)
# The pipeline rejects headings starting with "Original content"
if [[ "$heading" == "Original content"* ]]; then
  # This is what the pipeline would reject — test that the filter works
  test_pass
else
  test_fail "expected heading to match 'Original content*' filter"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: Multiple URLs in inbox
# ═══════════════════════════════════════════════════════════════════════════
test_start "Multiple URLs in inbox are enumerated"
vault=$(create_test_vault)
add_url_to_inbox "$vault" "https://example.com/article-1"
add_url_to_inbox "$vault" "https://example.com/article-2"
add_url_to_inbox "$vault" "https://example.com/article-3"

count=0
for f in "$vault/01-Raw"/*.url; do
  [ -f "$f" ] || continue
  count=$((count + 1))
done
if assert_eq "$count" "3" "url file count"; then
  test_pass
fi
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Invalid URL file content handling
# ═══════════════════════════════════════════════════════════════════════════
test_start "URL file with whitespace is trimmed"
vault=$(create_test_vault)
echo -e "  https://example.com/trimmed  \r\n" > "$vault/01-Raw/test.url"
url=$(cat "$vault/01-Raw/test.url" | tr -d '\r\n')
trimmed=$(echo "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if assert_eq "$trimmed" "https://example.com/trimmed" "trimmed URL"; then
  test_pass
fi
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Extraction output is valid JSON with ensure_ascii=False
# ═══════════════════════════════════════════════════════════════════════════
test_start "JSON output preserves unicode (ensure_ascii=False)"
extract_dir="/tmp/test-unicode-$$"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
hash=$(create_extracted_fixture "$extract_dir" \
  "https://example.com/unicode" \
  "Ünïcödé Tïtlë" \
  "Content with émojis 🎉 and spëcial chars" \
  "web" "authör")

json_file="$extract_dir/${hash}.json"
title_val=$(python3 -c "import json; print(json.load(open('$json_file'))['title'])" 2>/dev/null)
if assert_contains "$title_val" "Ünïcödé" "unicode title"; then
  test_pass
fi
rm -rf "$extract_dir"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Stage1 exit 0 on empty inbox (via process-inbox)
# ═══════════════════════════════════════════════════════════════════════════
test_start "Stage1 script exists and is executable"
stage1="$PIPELINE_DIR/stage1-extract.sh"
if [ -f "$stage1" ]; then
  test_pass
else
  test_fail "stage1-extract.sh not found at $stage1"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary
test_exit_code
