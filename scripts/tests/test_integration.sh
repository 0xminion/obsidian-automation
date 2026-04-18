#!/usr/bin/env bash
# ============================================================================
# Integration Test: Full Pipeline End-to-End (Simplified)
# Tests the pipeline by pre-populating Stage 1 output and running Stage 2+3.
# This avoids network dependencies while still testing the actual scripts.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

section "Integration: Pipeline Stages 2+3"

# ═══════════════════════════════════════════════════════════════════════════
# Setup: Create mock environment
# ═══════════════════════════════════════════════════════════════════════════

test_start "Setup test vault and mock extraction"

# Create temp vault
vault=$(create_test_vault)
export VAULT_PATH="$vault"
export LOG_FILE="$vault/Meta/Scripts/processing.log"

# Pre-populate extraction output (simulating Stage 1)
rm -rf /tmp/extracted
mkdir -p /tmp/extracted

# Create mock extraction data
h1=$(create_extracted_fixture "/tmp/extracted" \
  "https://blog.example.com/ai-forecasting" \
  "AI Forecasting: A Comprehensive Guide" \
  "# AI Forecasting: A Comprehensive Guide

Artificial intelligence is transforming how we make predictions about the future.
This article explores the intersection of AI and forecasting, covering key methods
such as machine learning models, ensemble techniques, and probabilistic approaches.

## Key Methods

1. **Neural networks** for time series prediction
2. **Bayesian methods** for uncertainty quantification
3. **Ensemble approaches** for robust predictions

The field has seen remarkable progress in recent years, with applications ranging
from weather prediction to financial markets and epidemiological modeling." \
  "web" "Jane Smith")

h2=$(create_extracted_fixture "/tmp/extracted" \
  "https://example.com/decentralized-governance" \
  "Decentralized Governance in Practice" \
  "# Decentralized Governance in Practice

How do decentralized organizations make decisions? This piece examines real-world
examples of decentralized governance, from DAOs to protocol governance.

## Case Studies

1. MakerDAO's executive voting system
2. Compound's Governor Bravo
3. Optimism's Citizens' House

Each case study reveals different tradeoffs between efficiency and decentralization." \
  "web" "Bob Johnson")

create_manifest "/tmp/extracted"

# Verify extraction output
assert_file_exists "/tmp/extracted/${h1}.json"
assert_file_exists "/tmp/extracted/${h2}.json"
assert_file_exists "/tmp/extracted/manifest.json"

manifest_count=$(python3 -c "import json; print(len(json.load(open('/tmp/extracted/manifest.json'))))" 2>/dev/null)
assert_eq "$manifest_count" "2" "manifest entry count"

# Create existing concepts for semantic matching
mkdir -p "$vault/04-Wiki/concepts"
cat > "$vault/04-Wiki/concepts/ai-and-machine-learning.md" << 'EOF'
---
title: "AI and Machine Learning"
type: concept
sources: []
tags: [concept, ai, machine-learning]
---

# AI and Machine Learning

## Core concept

Artificial intelligence encompasses systems that perform tasks requiring human-like intelligence.

## Context

Machine learning is a subset of AI focused on algorithms that learn from data.

## Links

- [[forecasting]]
EOF

cat > "$vault/04-Wiki/concepts/forecasting.md" << 'EOF'
---
title: "Forecasting"
type: concept
sources: []
tags: [concept, prediction, forecasting]
---

# Forecasting

## Core concept

Forecasting is the process of making predictions about future events based on past data.

## Context

Methods range from simple extrapolation to complex machine learning models.

## Links

- [[ai-and-machine-learning]]
EOF

test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Test 1: Stage 2 — Plan generation (with mocked agent)
# ═══════════════════════════════════════════════════════════════════════════

test_start "Stage 2: Plan generation"

# Create mock hermes that returns valid plans
mock_bin="/tmp/test-integration-mock-$$"
mkdir -p "$mock_bin"

cat > "$mock_bin/hermes" << 'MOCKSCRIPT'
#!/usr/bin/env bash
# Mock hermes — returns a valid plan for Stage 2
cat << 'PLANS'
[
  {
    "hash": "PLACEHOLDER_H1",
    "title": "AI Forecasting: A Comprehensive Guide",
    "language": "en",
    "template": "technical",
    "tags": ["ai", "forecasting", "machine-learning", "prediction"],
    "concept_updates": ["ai-and-machine-learning", "forecasting"],
    "concept_new": [],
    "moc_targets": []
  },
  {
    "hash": "PLACEHOLDER_H2",
    "title": "Decentralized Governance in Practice",
    "language": "en",
    "template": "standard",
    "tags": ["dao", "governance", "decentralization"],
    "concept_updates": [],
    "concept_new": ["Decentralized Governance"],
    "moc_targets": []
  }
]
PLANS
MOCKSCRIPT
chmod +x "$mock_bin/hermes"

# Replace placeholders with actual hashes
sed -i "s/PLACEHOLDER_H1/$h1/g" "$mock_bin/hermes"
sed -i "s/PLACEHOLDER_H2/$h2/g" "$mock_bin/hermes"

export PATH="$mock_bin:$PATH"
export AGENT_CMD="hermes"

# Run Stage 2
stage2_result=0
bash "$PIPELINE_DIR/stage2-plan.sh" 2>&1 || stage2_result=$?

if [ $stage2_result -ne 0 ]; then
  test_fail "Stage 2 returned non-zero: $stage2_result"
else
  # Verify plans.json exists
  assert_file_exists "/tmp/extracted/plans.json"
  
  # Verify plans content
  assert_json_valid "/tmp/extracted/plans.json"
  plan_count=$(python3 -c "import json; print(len(json.load(open('/tmp/extracted/plans.json'))))" 2>/dev/null)
  assert_eq "$plan_count" "2" "plan count"
  
  # Verify plan structure
  first_title=$(python3 -c "import json; print(json.load(open('/tmp/extracted/plans.json'))[0].get('title', ''))" 2>/dev/null)
  assert_contains "$first_title" "AI Forecasting" "first plan title"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 2: Stage 3 — Create notes
# ═══════════════════════════════════════════════════════════════════════════

test_start "Stage 3: Create notes"

# Create mock hermes for Stage 3 (returns note content)
cat > "$mock_bin/hermes" << 'MOCKSCRIPT3'
#!/usr/bin/env bash
# Mock hermes — creates actual note files for Stage 3
# Detect which batch we're processing from the prompt

vault="$VAULT_PATH"
mkdir -p "$vault/04-Wiki/sources"
mkdir -p "$vault/04-Wiki/entries"

# Read manifest to get hashes
manifest="/tmp/extracted/manifest.json"
if [ -f "$manifest" ]; then
  python3 << 'PYEOF'
import json, os

vault = os.environ.get("VAULT_PATH", "/tmp/test-vault")
manifest_path = "/tmp/extracted/manifest.json"

with open(manifest_path) as f:
    manifest = json.load(f)

for entry in manifest:
    h = entry.get("hash", "unknown")
    title = entry.get("title", "Untitled")
    url = entry.get("url", "")
    content = entry.get("content", "")
    source_type = entry.get("type", "web")
    
    # Create slug from title
    slug = title.lower().replace(" ", "-").replace(":", "").replace("/", "-")[:50]
    
    # Write source note
    source_path = f"{vault}/04-Wiki/sources/{slug}.md"
    with open(source_path, "w") as f:
        f.write(f"""---
title: "{title}"
source_url: "{url}"
source_type: {source_type}
date_captured: 2026-04-18
tags: [test, integration]
status: processed
---

# Original content

{content[:500]}
""")
    
    # Write entry note
    entry_path = f"{vault}/04-Wiki/entries/{slug}.md"
    with open(entry_path, "w") as f:
        f.write(f"""---
title: "{title}"
source: "[[{slug}]]"
date_entry: 2026-04-18
status: review
reviewed: ""
template: standard
tags: [test, integration]
---

# {title}

## Summary

This is a test entry created by the integration test.

## Core insights

1. First key insight from the source.
2. Second important finding.

## Other takeaways

3. Additional context worth noting.

## Diagrams

n/a

## Open questions

- What are the implications of this?

## Linked concepts

- [[ai-and-machine-learning]]
""")

print("Created notes successfully")
PYEOF
fi

echo "Done"
exit 0
MOCKSCRIPT3
chmod +x "$mock_bin/hermes"

# Run Stage 3
stage3_result=0
PARALLEL=1 bash "$PIPELINE_DIR/stage3-create.sh" 2>&1 || stage3_result=$?

if [ $stage3_result -ne 0 ]; then
  test_fail "Stage 3 returned non-zero: $stage3_result"
else
  # Verify files were created
  source_count=$(find "$vault/04-Wiki/sources" -name "*.md" | wc -l)
  entry_count=$(find "$vault/04-Wiki/entries" -name "*.md" | wc -l)
  
  assert_gt "$source_count" "0" "source notes created"
  assert_gt "$entry_count" "0" "entry notes created"
  
  # Verify frontmatter in created files
  if [ "$source_count" -gt 0 ]; then
    first_source=$(find "$vault/04-Wiki/sources" -name "*.md" | head -1)
    if [ -f "$first_source" ]; then
      # Check for YAML frontmatter
      first_line=$(head -1 "$first_source")
      assert_eq "$first_line" "---" "source has YAML frontmatter"
      
      # Check for required fields
      if grep -q "title:" "$first_source" && grep -q "source_url:" "$first_source"; then
        test_pass
      else
        test_fail "source missing required fields"
      fi
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 3: Output validation
# ═══════════════════════════════════════════════════════════════════════════

test_start "validate-output.sh on created files"

if [ "$(find "$vault/04-Wiki" -name "*.md" | wc -l)" -gt 0 ]; then
  validate_result=0
  bash "$PIPELINE_DIR/validate-output.sh" --vault "$vault" 2>&1 || validate_result=$?
  
  # Validation may find warnings but should not crash
  # Exit code 0 = all good, 1 = violations, 2 = fatal error
  if [ $validate_result -le 1 ]; then
    test_pass
  else
    test_fail "validate-output fatal error (exit code $validate_result)"
  fi
else
  test_fail "No files to validate"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 4: File structure validation
# ═══════════════════════════════════════════════════════════════════════════

test_start "File structure and frontmatter validation"

all_ok=true

# Check all source notes have proper frontmatter
for source_file in "$vault/04-Wiki/sources"/*.md; do
  [ -f "$source_file" ] || continue
  
  # Check YAML frontmatter exists
  first_line=$(head -1 "$source_file")
  if [ "$first_line" != "---" ]; then
    all_ok=false
    test_fail "Missing YAML frontmatter: $(basename "$source_file")"
    break
  fi
  
  # Check required fields
  if ! grep -q "title:" "$source_file"; then
    all_ok=false
    test_fail "Missing title field: $(basename "$source_file")"
    break
  fi
done

# Check all entry notes have proper frontmatter
for entry_file in "$vault/04-Wiki/entries"/*.md; do
  [ -f "$entry_file" ] || continue
  
  # Check YAML frontmatter exists
  first_line=$(head -1 "$entry_file")
  if [ "$first_line" != "---" ]; then
    all_ok=false
    test_fail "Missing YAML frontmatter: $(basename "$entry_file")"
    break
  fi
  
  # Check required sections
  if ! grep -q "## Summary" "$entry_file"; then
    all_ok=false
    test_fail "Missing Summary section: $(basename "$entry_file")"
    break
  fi
  
  if ! grep -q "## Core insights" "$entry_file"; then
    all_ok=false
    test_fail "Missing Core insights section: $(basename "$entry_file")"
    break
  fi
done

if $all_ok; then
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 5: Full pipeline dry-run
# ═══════════════════════════════════════════════════════════════════════════

test_start "Full pipeline: process-inbox.sh --dry-run"

vault2=$(create_test_vault)
add_url_to_inbox "$vault2" "https://example.com/dry-run-test"

dry_run_output=$(VAULT_PATH="$vault2" bash "$PIPELINE_DIR/process-inbox.sh" --dry-run 2>&1)
dry_run_result=$?

assert_eq "$dry_run_result" "0" "dry-run exit code"
assert_contains "$dry_run_output" "DRY RUN" "dry-run message"

cleanup_test_vault "$vault2"

# ═══════════════════════════════════════════════════════════════════════════
# Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup_test_vault "$vault"
rm -rf "$mock_bin"
rm -rf /tmp/extracted

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Integration Tests: $_TESTS_RUN run, $_TESTS_PASSED passed, $_TESTS_FAILED failed"
echo "════════════════════════════════════════════════════════════════"

if [ $_TESTS_FAILED -gt 0 ]; then
  echo ""
  echo "Failures:"
  echo -e "$_FAILURES"
  exit 1
fi

exit 0
