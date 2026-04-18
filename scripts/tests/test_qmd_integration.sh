#!/usr/bin/env bash
# ============================================================================
# QMD Integration Tests — Semantic Concept Search
# Tests: qmd availability, concept search, fallback behavior, batch search
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/../../lib/common.sh"

section "QMD Semantic Concept Search"

# ═══════════════════════════════════════════════════════════════════════════
# Test: qmd binary exists
# ═══════════════════════════════════════════════════════════════════════════
test_start "qmd binary is available"
if command -v qmd &>/dev/null; then
  test_pass
else
  test_fail "qmd not found in PATH"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: qmd_available() function works
# ═══════════════════════════════════════════════════════════════════════════
test_start "qmd_available() detects concepts collection"
if qmd_available 2>/dev/null; then
  test_pass
else
  test_fail "qmd_installed but concepts collection not found (run setup-qmd.sh)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: qmd_concept_search returns valid JSON with results
# ═══════════════════════════════════════════════════════════════════════════
test_start "qmd_concept_search returns valid JSON array with results"
export VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
export LOG_FILE="/dev/null"
result=$(qmd_concept_search "prediction markets" 3 0.1 2>/dev/null)
result_count=$(echo "$result" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(len(d) if isinstance(d, list) else -1)
except:
    print(-1)
" 2>/dev/null || echo "-1")
if [ "$result_count" -gt 0 ] 2>/dev/null; then
  test_pass
else
  test_fail "expected >0 results, got: $result_count (output: ${result:0:100})"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: qmd_concept_search finds prediction-markets
# ═══════════════════════════════════════════════════════════════════════════
test_start "qmd_concept_search finds prediction-markets concept"
result=$(qmd_concept_search "prediction markets and forecasting" 5 0.1 2>/dev/null)
found=$(echo "$result" | python3 -c "
import json, sys
results = json.load(sys.stdin)
for r in results:
    f = r.get('file', '')
    if 'prediction-markets' in f:
        print('found')
        break
else:
    print('not_found')
" 2>/dev/null || echo "not_found")
if [ "$found" = "found" ]; then
  test_pass
else
  test_fail "prediction-markets not found in results: ${result:0:200}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: qmd_results_to_names extracts concept names correctly
# ═══════════════════════════════════════════════════════════════════════════
test_start "qmd_results_to_names extracts concept names from paths"
mock_json='[{"file":"qmd://concepts/prediction-markets.md","score":0.9},{"file":"qmd://concepts/forecasting.md","score":0.5}]'
names=$(qmd_results_to_names "$mock_json")
has_pm=$(echo "$names" | python3 -c "import json,sys; print('yes' if 'prediction-markets' in json.load(sys.stdin) else 'no')" 2>/dev/null || echo "no")
has_fc=$(echo "$names" | python3 -c "import json,sys; print('yes' if 'forecasting' in json.load(sys.stdin) else 'no')" 2>/dev/null || echo "no")
if [ "$has_pm" = "yes" ] && [ "$has_fc" = "yes" ]; then
  test_pass
else
  test_fail "name extraction failed: $names"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: qmd_concept_search fallback when qmd unavailable
# ═══════════════════════════════════════════════════════════════════════════
test_start "qmd_concept_search returns [] when qmd unavailable"
SAVED_QMD_CMD="$QMD_CMD"
QMD_CMD="/nonexistent/qmd"
result=$(qmd_concept_search "test query" 3 0.3 2>/dev/null)
QMD_CMD="$SAVED_QMD_CMD"
is_empty=$(echo "$result" | python3 -c "import json,sys; print('empty' if json.load(sys.stdin)==[] else 'not_empty')" 2>/dev/null || echo "not_empty")
if [ "$is_empty" = "empty" ]; then
  test_pass
else
  test_fail "expected empty array fallback, got: ${result:0:100}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: qmd_batch_concept_search returns correct format with matches
# ═══════════════════════════════════════════════════════════════════════════
test_start "qmd_batch_concept_search returns {hash: [names]} with real matches"
mock_manifest='[{"hash":"abc123","title":"Prediction Markets Guide","content":"How prediction markets work for forecasting future events with financial incentives."}]'
result=$(qmd_batch_concept_search "$mock_manifest" 2>/dev/null)
is_valid=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict) or 'abc123' not in d:
    print('invalid_dict')
elif len(d['abc123']) > 0:
    print('valid_with_matches')
else:
    print('valid_empty')
" 2>/dev/null || echo "invalid")
if [ "$is_valid" = "valid_with_matches" ]; then
  test_pass
else
  # If qmd wasn't available, empty is acceptable
  if [ "$is_valid" = "valid_empty" ] && ! qmd_available 2>/dev/null; then
    test_pass
  else
    test_fail "batch search result: $is_valid (output: ${result:0:200})"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: cmake noise is stripped from qmd output
# ═══════════════════════════════════════════════════════════════════════════
test_start "cmake/Vulkan noise is stripped from qmd output"
result=$(qmd_concept_search "prediction markets" 3 0.1 2>/dev/null)
# Result should start with '[' (valid JSON array) — no cmake prefix like 'Not searching' or 'CMake Error'
starts_with_bracket=$(echo "$result" | python3 -c "
import sys
text = sys.stdin.read().lstrip()
print('yes' if text.startswith('[') else 'no')
" 2>/dev/null || echo "no")
is_valid_json=$(echo "$result" | python3 -c "import json,sys; json.load(sys.stdin); print('yes')" 2>/dev/null || echo "no")
if [ "$starts_with_bracket" = "yes" ] && [ "$is_valid_json" = "yes" ]; then
  test_pass
else
  test_fail "output doesn't start with clean JSON: ${result:0:150}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test: setup-qmd.sh exists and is executable
# ═══════════════════════════════════════════════════════════════════════════
test_start "setup-qmd.sh exists and is executable"
if [ -x "$SCRIPT_DIR/../setup-qmd.sh" ]; then
  test_pass
else
  test_fail "setup-qmd.sh not found or not executable"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary
test_exit_code
