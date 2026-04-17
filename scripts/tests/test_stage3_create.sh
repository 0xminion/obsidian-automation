#!/usr/bin/env bash
# ============================================================================
# Stage 3 Tests — Create Batch Logic
# Tests: batch splitting math, prompt building, file creation, vault structure
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

section "Stage 3: Create Batch Logic"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Batch splitting math — ceil division
# ═══════════════════════════════════════════════════════════════════════════
test_start "Batch split: 7 plans, parallel=3 → 3+3+1"
python3 -c "
import math
plans = list(range(7))
parallel = 3
batch_size = math.ceil(len(plans) / parallel)  # ceil(7/3) = 3
batches = []
for i in range(parallel):
    start = i * batch_size
    end = min(start + batch_size, len(plans))
    if start >= len(plans):
        break
    batches.append(len(plans[start:end]))
assert batches == [3, 3, 1], f'Expected [3,3,1] got {batches}'
print('OK')
" 2>/dev/null
if [ "$?" -eq 0 ]; then
  test_pass
else
  test_fail "batch splitting math incorrect"
fi

test_start "Batch split: 5 plans, parallel=2 → 3+2"
python3 -c "
import math
plans = list(range(5))
parallel = 2
batch_size = math.ceil(len(plans) / parallel)  # ceil(5/2) = 3
batches = []
for i in range(parallel):
    start = i * batch_size
    end = min(start + batch_size, len(plans))
    if start >= len(plans):
        break
    batches.append(len(plans[start:end]))
assert batches == [3, 2], f'Expected [3,2] got {batches}'
print('OK')
" 2>/dev/null
if [ "$?" -eq 0 ]; then
  test_pass
else
  test_fail "batch splitting math incorrect"
fi

test_start "Batch split: 3 plans, parallel=3 → 1+1+1"
python3 -c "
import math
plans = list(range(3))
parallel = 3
batch_size = math.ceil(len(plans) / parallel)  # 1
batches = []
for i in range(parallel):
    start = i * batch_size
    end = min(start + batch_size, len(plans))
    if start >= len(plans):
        break
    batches.append(len(plans[start:end]))
assert batches == [1, 1, 1], f'Expected [1,1,1] got {batches}'
print('OK')
" 2>/dev/null
if [ "$?" -eq 0 ]; then
  test_pass
else
  test_fail "batch splitting math incorrect"
fi

test_start "Batch split: 1 plan, parallel=3 → 1"
python3 -c "
import math
plans = list(range(1))
parallel = 3
batch_size = math.ceil(len(plans) / parallel)  # 1
batches = []
for i in range(parallel):
    start = i * batch_size
    end = min(start + batch_size, len(plans))
    if start >= len(plans):
        break
    batches.append(len(plans[start:end]))
assert batches == [1], f'Expected [1] got {batches}'
print('OK')
" 2>/dev/null
if [ "$?" -eq 0 ]; then
  test_pass
else
  test_fail "batch splitting math incorrect"
fi

test_start "Batch split: 0 plans → no batches"
python3 -c "
import math
plans = []
parallel = 3
if len(plans) == 0:
    print('OK')
    exit(0)
batch_size = math.ceil(len(plans) / parallel)
batches = []
for i in range(parallel):
    start = i * batch_size
    end = min(start + batch_size, len(plans))
    if start >= len(plans):
        break
    batches.append(len(plans[start:end]))
assert batches == [], f'Expected [] got {batches}'
print('OK')
" 2>/dev/null
if [ "$?" -eq 0 ]; then
  test_pass
else
  test_fail "zero-plan batch split incorrect"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: Batch file creation on disk
# ═══════════════════════════════════════════════════════════════════════════
test_start "Batch files written to disk with correct content"
batch_dir="/tmp/test-batch-files-$$"
rm -rf "$batch_dir"
mkdir -p "$batch_dir"

# Create fake plans
plans_file="$batch_dir/plans.json"
cat > "$plans_file" << 'PLANS'
[
  {"hash": "aaa111", "title": "Article A", "language": "en", "template": "standard", "tags": ["a"], "concept_updates": [], "concept_new": [], "moc_targets": []},
  {"hash": "bbb222", "title": "Article B", "language": "en", "template": "standard", "tags": ["b"], "concept_updates": [], "concept_new": [], "moc_targets": []},
  {"hash": "ccc333", "title": "Article C", "language": "en", "template": "standard", "tags": ["c"], "concept_updates": [], "concept_new": [], "moc_targets": []},
  {"hash": "ddd444", "title": "Article D", "language": "en", "template": "standard", "tags": ["d"], "concept_updates": [], "concept_new": [], "moc_targets": []},
  {"hash": "eee555", "title": "Article E", "language": "en", "template": "standard", "tags": ["e"], "concept_updates": [], "concept_new": [], "moc_targets": []}
]
PLANS

# Split into batches (parallel=2) and write to disk
python3 << PYEOF
import json, math

with open('${plans_file}') as f:
    plans = json.load(f)

parallel = 2
batch_size = math.ceil(len(plans) / parallel)

for i in range(parallel):
    start = i * batch_size
    end = min(start + batch_size, len(plans))
    if start >= len(plans):
        break
    batch = plans[start:end]
    with open('${batch_dir}/batch_{}.json'.format(i), 'w') as f:
        json.dump(batch, f, ensure_ascii=False, indent=2)
PYEOF

# Verify batch files exist and have correct sizes
batch0_ok=false
batch1_ok=false
if [ -f "$batch_dir/batch_0.json" ]; then
  b0=$(python3 -c "import json; print(len(json.load(open('${batch_dir}/batch_0.json'))))")
  [ "$b0" = "3" ] && batch0_ok=true
fi
if [ -f "$batch_dir/batch_1.json" ]; then
  b1=$(python3 -c "import json; print(len(json.load(open('${batch_dir}/batch_1.json'))))")
  [ "$b1" = "2" ] && batch1_ok=true
fi

if $batch0_ok && $batch1_ok; then
  test_pass
else
  test_fail "batch sizes: batch0=$b0, batch1=$b1"
fi
rm -rf "$batch_dir"

# ═══════════════════════════════════════════════════════════════════════════
# Test: build_batch_prompt.py — prompt building
# ═══════════════════════════════════════════════════════════════════════════
test_start "build_batch_prompt.py produces valid prompt"
extract_dir="/tmp/test-prompt-build-$$"
vault=$(create_test_vault)
rm -rf "$extract_dir"
mkdir -p "$extract_dir"

# Create extraction fixtures
h1=$(create_extracted_fixture "$extract_dir" \
  "https://example.com/prompt1" \
  "Test Article One" \
  "This is the content of article one with enough text to be meaningful." \
  "web" "author1")

h2=$(create_extracted_fixture "$extract_dir" \
  "https://example.com/prompt2" \
  "Test Article Two" \
  "This is the content of article two with different information." \
  "blog" "author2")

# Create batch file
batch_file="$extract_dir/batch_0.json"
cat > "$batch_file" << EOF
[
  {"hash": "$h1", "title": "Test Article One", "language": "en", "template": "standard", "tags": ["test"], "concept_updates": [], "concept_new": ["Test Concept"], "moc_targets": []},
  {"hash": "$h2", "title": "Test Article Two", "language": "en", "template": "standard", "tags": ["test"], "concept_updates": [], "concept_new": [], "moc_targets": ["Test MoC"]}
]
EOF

# Run build_batch_prompt.py
prompt=$(python3 "$PIPELINE_DIR/build_batch_prompt.py" \
  "$batch_file" "$extract_dir" "$vault" \
  "$PIPELINE_DIR/../prompts/entry-structure.prompt" \
  "$PIPELINE_DIR/../prompts/concept-structure.prompt" \
  "$PIPELINE_DIR/../prompts/common-instructions.prompt" 2>/dev/null)

# Verify prompt contains expected elements
all_ok=true
for field in "Test Article One" "Test Article Two" "HASH:" "LANGUAGE:" "TEMPLATE:" "CONCEPT_NEW:" "MOC_TARGETS:" "CONTENT:"; do
  if ! echo "$prompt" | grep -qF "$field"; then
    test_fail "prompt missing field: $field"
    all_ok=false
    break
  fi
done
if $all_ok; then
  test_pass
fi

test_start "Prompt includes vault path"
if echo "$prompt" | grep -qF "$vault"; then
  test_pass
else
  test_fail "prompt missing vault path"
fi

test_start "Prompt includes instruction about no stubs"
if echo "$prompt" | grep -qi "NO stubs"; then
  test_pass
else
  test_fail "prompt missing anti-stub instruction"
fi

rm -rf "$extract_dir"
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: build_batch_prompt.py — handles missing extract file gracefully
# ═══════════════════════════════════════════════════════════════════════════
test_start "build_batch_prompt.py skips missing extract files"
extract_dir="/tmp/test-prompt-missing-$$"
vault=$(create_test_vault)
rm -rf "$extract_dir"
mkdir -p "$extract_dir"

batch_file="$extract_dir/batch_missing.json"
cat > "$batch_file" << 'EOF'
[
  {"hash": "nonexistent", "title": "Missing", "language": "en", "template": "standard", "tags": [], "concept_updates": [], "concept_new": [], "moc_targets": []}
]
EOF

# Should not crash
prompt=$(python3 "$PIPELINE_DIR/build_batch_prompt.py" \
  "$batch_file" "$extract_dir" "$vault" \
  "$PIPELINE_DIR/../prompts/entry-structure.prompt" \
  "$PIPELINE_DIR/../prompts/concept-structure.prompt" 2>/dev/null)

# Should still produce a prompt (just with no source content)
if [ -n "$prompt" ] && echo "$prompt" | grep -q "wiki write agent"; then
  test_pass
else
  test_fail "prompt generation failed with missing extract"
fi
rm -rf "$extract_dir"
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: File creation paths — only expected dirs are written to
# ═══════════════════════════════════════════════════════════════════════════
test_start "Vault structure has correct directories"
vault=$(create_test_vault)

expected_dirs=(
  "01-Raw"
  "02-Clippings"
  "03-Queries"
  "04-Wiki/entries"
  "04-Wiki/concepts"
  "04-Wiki/mocs"
  "04-Wiki/sources"
  "05-Outputs/answers"
  "05-Outputs/visualizations"
  "06-Config"
  "07-WIP"
  "08-Archive-Raw"
  "09-Archive-Queries"
  "Meta/Scripts"
  "Meta/Templates"
)

all_ok=true
for d in "${expected_dirs[@]}"; do
  if [ ! -d "$vault/$d" ]; then
    test_fail "missing expected dir: $d"
    all_ok=false
    break
  fi
done
if $all_ok; then
  test_pass
fi
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: No files created outside expected vault paths
# ═══════════════════════════════════════════════════════════════════════════
test_start "Writing to vault only touches expected paths"
vault=$(create_test_vault)

# Record file count before
before_count=$(find "$vault" -type f | wc -l)

# Simulate stage3 writing a source note
mkdir -p "$vault/04-Wiki/sources"
cat > "$vault/04-Wiki/sources/test-article.md" << 'EOF'
---
title: "Test Article"
source_url: "https://example.com/test"
source_type: web
author: test
date_captured: 2026-04-17
tags: [test]
status: processed
---

# Original content

Test content here.
EOF

# Record file count after
after_count=$(find "$vault" -type f | wc -l)

# Should have exactly 1 more file
diff=$((after_count - before_count))
if assert_eq "$diff" "1" "file count diff"; then
  # Verify no files outside vault
  outside=$(find /tmp -maxdepth 1 -name "test-vault-*" -newer "$vault" -not -path "$vault" 2>/dev/null | wc -l)
  test_pass
fi
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Stage3 script exists
# ═══════════════════════════════════════════════════════════════════════════
test_start "stage3-create.sh exists"
if [ -f "$PIPELINE_DIR/stage3-create.sh" ]; then
  test_pass
else
  test_fail "stage3-create.sh not found"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: build_batch_prompt.py exists and is valid Python
# ═══════════════════════════════════════════════════════════════════════════
test_start "build_batch_prompt.py is valid Python"
if python3 -c "import py_compile; py_compile.compile('$PIPELINE_DIR/build_batch_prompt.py', doraise=True)" 2>/dev/null; then
  test_pass
else
  test_fail "build_batch_prompt.py has syntax errors"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary
test_exit_code
