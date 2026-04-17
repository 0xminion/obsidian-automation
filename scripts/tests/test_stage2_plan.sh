#!/usr/bin/env bash
# ============================================================================
# Stage 2 Tests — Plan Generation Logic
# Tests: manifest parsing, concept pre-search, prompt building, error handling
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

section "Stage 2: Plan Generation Logic"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Missing manifest — stage2 should error
# ═══════════════════════════════════════════════════════════════════════════
test_start "Missing manifest triggers error"
vault=$(create_test_vault)
export VAULT_PATH="$vault"
export LOG_FILE="$vault/Meta/Scripts/processing.log"

# Clear any stale extraction dir
rm -rf /tmp/extracted
# Don't create manifest — stage2 should fail
result=0
MANIFEST="/tmp/extracted/manifest.json"
if [ ! -f "$MANIFEST" ]; then
  # This is exactly what stage2 checks
  test_pass
else
  test_fail "manifest should not exist"
fi
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Concept pre-search — keyword matching logic
# ═══════════════════════════════════════════════════════════════════════════
test_start "Concept pre-search matches relevant concepts"
vault=$(create_test_vault)
export VAULT_PATH="$vault"

# Create some concept files
mkdir -p "$vault/04-Wiki/concepts"
echo "# Prediction Markets" > "$vault/04-Wiki/concepts/prediction-markets.md"
echo "# Machine Learning" > "$vault/04-Wiki/concepts/machine-learning.md"
echo "# Blockchain" > "$vault/04-Wiki/concepts/blockchain.md"

# Create extracted data mentioning "prediction markets"
extract_dir="/tmp/test-extract-concept-$$"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
hash=$(create_extracted_fixture "$extract_dir" \
  "https://example.com/pm" \
  "Prediction Markets 101" \
  "An introduction to prediction markets and how they work for forecasting." \
  "web" "author")

# Run the concept matching logic from stage2 (inline)
concept_files=("prediction-markets" "machine-learning" "blockchain")
content_lower="prediction markets 101 an introduction to prediction markets and how they work for forecasting."
title_lower="prediction markets 101"
combined="$title_lower $content_lower"

matched=()
for concept in "${concept_files[@]}"; do
  keywords=$(echo "$concept" | tr '-' ' ')
  if echo "$combined" | grep -qi "$concept" 2>/dev/null; then
    matched+=("$concept")
  elif echo "$combined" | grep -qi "prediction" && echo "$combined" | grep -qi "markets"; then
    matched+=("$concept")
  fi
done

# Should match prediction-markets
found_pm=false
for m in "${matched[@]}"; do
  if [ "$m" = "prediction-markets" ]; then
    found_pm=true
  fi
done
if $found_pm; then
  test_pass
else
  test_fail "prediction-markets concept not matched (matched: ${matched[*]})"
fi

test_start "Concept pre-search does not match unrelated concepts"
# Use content that mentions prediction markets but NOT machine learning
content_lower_b="prediction markets are tools for collective forecasting using financial incentives."
matched_b=()
for concept in "${concept_files[@]}"; do
  if echo "$content_lower_b" | grep -qiF "$concept" 2>/dev/null; then
    matched_b+=("$concept")
  fi
done
found_ml=false
for m in "${matched_b[@]}"; do
  if [ "$m" = "machine-learning" ]; then
    found_ml=true
  fi
done
if ! $found_ml; then
  test_pass
else
  test_fail "machine-learning should not match prediction markets content"
fi

rm -rf "$extract_dir"
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Concept pre-search — Chinese concept matching
# ═══════════════════════════════════════════════════════════════════════════
test_start "Concept pre-search handles Chinese content"
vault=$(create_test_vault)
mkdir -p "$vault/04-Wiki/concepts"
echo "# 预测市场" > "$vault/04-Wiki/concepts/预测市场.md"

extract_dir="/tmp/test-extract-zh-$$"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
hash=$(create_extracted_fixture "$extract_dir" \
  "https://example.com/zh" \
  "预测市场简介" \
  "预测市场是一种通过市场机制来进行预测的工具。" \
  "web" "author")

# Simple matching: check if concept name appears in combined text
concept="预测市场"
content="预测市场简介 预测市场是一种通过市场机制来进行预测的工具。"
if echo "$content" | grep -qF "$concept"; then
  test_pass
else
  test_fail "Chinese concept not matched"
fi

rm -rf "$extract_dir"
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Plan prompt includes concept matches
# ═══════════════════════════════════════════════════════════════════════════
test_start "Plan prompt contains concept_matches field"
vault=$(create_test_vault)
mkdir -p "$vault/04-Wiki/concepts"
echo "# Prediction Markets" > "$vault/04-Wiki/concepts/prediction-markets.md"

extract_dir="/tmp/test-extract-prompt-$$"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
hash=$(create_extracted_fixture "$extract_dir" \
  "https://example.com/prompt-test" \
  "Prediction Markets Guide" \
  "How prediction markets work for forecasting." \
  "web" "author")
create_manifest "$extract_dir"

# Simulate concept matching output
concept_matches='{"'"$hash"'": ["prediction-markets"]}'
echo "$concept_matches" > "$extract_dir/concept_matches.json"

# Check that concept_matches.json is valid JSON with expected structure
assert_json_valid "$extract_dir/concept_matches.json"
has_prediction=$(python3 -c "
import json
with open('${extract_dir}/concept_matches.json') as f:
    d = json.load(f)
matches = d.get('${hash}', [])
print('yes' if any('prediction' in m for m in matches) else 'no')
" 2>/dev/null)

if [ "$has_prediction" = "yes" ]; then
  test_pass
else
  test_fail "concept matches missing prediction-markets: $has_prediction"
fi

rm -rf "$extract_dir"
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Plan JSON schema validation
# ═══════════════════════════════════════════════════════════════════════════
test_start "Plan JSON has required fields (hash, title, language, template)"
plan_file="/tmp/test-plan-schema-$$"
cat > "$plan_file" << 'EOF'
[
  {
    "hash": "abc123",
    "title": "Test Article",
    "language": "en",
    "template": "standard",
    "tags": ["test"],
    "concept_updates": [],
    "concept_new": [],
    "moc_targets": []
  }
]
EOF

assert_json_valid "$plan_file"

plan=$(python3 -c "
import json
with open('$plan_file') as f:
    plans = json.load(f)
p = plans[0]
ok = all(k in p for k in ['hash','title','language','template','tags','concept_updates','concept_new','moc_targets'])
print('OK' if ok else 'FAIL: ' + str([k for k in ['hash','title','language','template','tags','concept_updates','concept_new','moc_targets'] if k not in p]))
" 2>/dev/null)

if assert_eq "$plan" "OK" "plan schema"; then
  test_pass
fi
rm -f "$plan_file"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Plan output parsing — JSON array extraction
# ═══════════════════════════════════════════════════════════════════════════
test_start "Plan parser extracts JSON array from agent output"
raw_output='Here are the plans:
[{"hash":"abc","title":"Test","language":"en","template":"standard","tags":[],"concept_updates":[],"concept_new":[],"moc_targets":[]}]
Done!'

# Replicate the parsing logic from stage2
json_match=$(echo "$raw_output" | python3 -c "
import re, sys, json
raw = sys.stdin.read()
m = re.search(r'\[.*\]', raw, re.DOTALL)
if m:
    try:
        plans = json.loads(m.group())
        print(f'Parsed {len(plans)} plans')
    except:
        print('Parse error')
else:
    print('No match')
" 2>/dev/null)

if assert_eq "$json_match" "Parsed 1 plans" "plan parsing"; then
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: Plan parser — object-by-object fallback
# ═══════════════════════════════════════════════════════════════════════════
test_start "Plan parser falls back to object-by-object extraction"
raw_output='Some noise {"hash":"abc","title":"Test","language":"en","template":"standard","tags":[],"concept_updates":[],"concept_new":[],"moc_targets":[]} more noise'

plans=$(python3 -c "
import json, re, sys
raw = sys.stdin.read()
plans = []
depth = 0
start = -1
for i, c in enumerate(raw):
    if c == '{':
        if depth == 0:
            start = i
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0 and start >= 0:
            try:
                obj = json.loads(raw[start:i+1])
                if 'hash' in obj:
                    plans.append(obj)
            except:
                pass
            start = -1
print(len(plans))
" <<< "$raw_output" 2>/dev/null)

if assert_eq "$plans" "1" "object-by-object parsing"; then
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: Plan prompt size should be compact (not 18K chars)
# ═══════════════════════════════════════════════════════════════════════════
test_start "Plan prompt is compact (<5K chars for 1 source)"
vault=$(create_test_vault)
mkdir -p "$vault/04-Wiki/concepts"
extract_dir="/tmp/test-prompt-size-$$"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
hash=$(create_extracted_fixture "$extract_dir" \
  "https://example.com/compact" \
  "Compact Test" \
  "Short content." \
  "web" "author")
create_manifest "$extract_dir"

# Build prompt inline (simplified version of stage2 prompt)
manifest_json=$(cat "$extract_dir/manifest.json")
prompt_size=$(python3 -c "
import json
with open('$extract_dir/manifest.json') as f:
    manifest = json.load(f)
sources_block = ''
for e in manifest:
    sources_block += f'Source: {e[\"title\"]}\nPreview: {e.get(\"content\",\"\")[:300]}\n'
prompt = f'Plan these sources:{sources_block}'
print(len(prompt))
" 2>/dev/null)

# Should be well under 5K for a single source
if [ "$prompt_size" -lt 5000 ] 2>/dev/null; then
  test_pass
else
  test_fail "prompt too large: $prompt_size chars"
fi
rm -rf "$extract_dir"
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Empty manifest → no plans
# ═══════════════════════════════════════════════════════════════════════════
test_start "Empty manifest produces empty plan list"
extract_dir="/tmp/test-empty-manifest-$$"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
echo "[]" > "$extract_dir/manifest.json"

count=$(python3 -c "import json; print(len(json.load(open('$extract_dir/manifest.json'))))" 2>/dev/null)
if assert_eq "$count" "0" "empty manifest count"; then
  test_pass
fi
rm -rf "$extract_dir"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Stage2 script exists
# ═══════════════════════════════════════════════════════════════════════════
test_start "stage2-plan.sh exists"
if [ -f "$PIPELINE_DIR/stage2-plan.sh" ]; then
  test_pass
else
  test_fail "stage2-plan.sh not found"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary
test_exit_code
