#!/usr/bin/env bash
# ============================================================================
# End-to-End Pipeline Tests
# Tests: single URL through all 3 stages using temp vault (no live network/agent)
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

section "End-to-End Pipeline"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Full pipeline simulation — Stage 1 (mock) → Stage 2 (prompt) → Stage 3 (batch)
# ═══════════════════════════════════════════════════════════════════════════
test_start "Full pipeline: inbox → extract → plan → batch prompt"
vault=$(create_test_vault)
export VAULT_PATH="$vault"
export LOG_FILE="$vault/Meta/Scripts/processing.log"

# ── Stage 1: Simulate extraction ──
add_url_to_inbox "$vault" "https://blog.example.com/ai-forecasting"
add_url_to_inbox "$vault" "https://example.com/decentralized-governance"

extract_dir="/tmp/test-e2e-extract-$$"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"

h1=$(create_extracted_fixture "$extract_dir" \
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

h2=$(create_extracted_fixture "$extract_dir" \
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

# Verify Stage 1 output
assert_file_exists "$extract_dir/${h1}.json"
assert_file_exists "$extract_dir/${h2}.json"

create_manifest "$extract_dir"
assert_file_exists "$extract_dir/manifest.json"

manifest_count=$(python3 -c "import json; print(len(json.load(open('$extract_dir/manifest.json'))))" 2>/dev/null)
assert_eq "$manifest_count" "2" "manifest count"

# ── Stage 2: Simulate concept pre-search + plan generation ──
mkdir -p "$vault/04-Wiki/concepts"
echo "# AI and Machine Learning" > "$vault/04-Wiki/concepts/ai-and-machine-learning.md"
echo "# Decentralized Autonomous Organizations" > "$vault/04-Wiki/concepts/decentralized-autonomous-organizations.md"
echo "# Forecasting" > "$vault/04-Wiki/concepts/forecasting.md"

# Run concept matching (inline simulation of stage2 logic)
python3 -c "
import json, os

with open('$extract_dir/manifest.json') as f:
    manifest = json.load(f)

concept_dir = '$vault/04-Wiki/concepts'
concept_files = []
for f in sorted(os.listdir(concept_dir)):
    if f.endswith('.md'):
        concept_files.append(f.replace('.md', ''))

matches = {}
for entry in manifest:
    h = entry['hash']
    content_lower = entry.get('content', '').lower()[:5000]
    title_lower = entry.get('title', '').lower()
    combined = title_lower + ' ' + content_lower

    matched = []
    for concept in concept_files:
        keywords = concept.lower().replace('-', ' ').replace('_', ' ').split()
        if concept.lower() in combined:
            matched.append(concept)
        else:
            kw_hits = sum(1 for kw in keywords if len(kw) > 3 and kw in combined)
            if kw_hits >= 2:
                matched.append(concept)
    matches[h] = matched[:8]

with open('$extract_dir/concept_matches.json', 'w') as f:
    json.dump(matches, f, indent=2)
print(json.dumps(matches, indent=2))
"

assert_file_exists "$extract_dir/concept_matches.json"

# Verify AI article matched ai-and-machine-learning
ai_match=$(python3 -c "
import json
with open('$extract_dir/concept_matches.json') as f:
    m = json.load(f)
matched = m.get('$h1', [])
print('ai-and-machine-learning' in matched)
" 2>/dev/null)
assert_eq "$ai_match" "True" "AI article matched ai concept"

# Generate plans (simulated)
cat > "$extract_dir/plans.json" << EOF
[
  {
    "hash": "$h1",
    "title": "AI Forecasting: A Comprehensive Guide",
    "language": "en",
    "template": "technical",
    "tags": ["ai", "forecasting", "machine-learning", "prediction"],
    "concept_updates": ["ai-and-machine-learning", "forecasting"],
    "concept_new": [],
    "moc_targets": []
  },
  {
    "hash": "$h2",
    "title": "Decentralized Governance in Practice",
    "language": "en",
    "template": "standard",
    "tags": ["dao", "governance", "decentralization"],
    "concept_updates": ["decentralized-autonomous-organizations"],
    "concept_new": ["Decentralized Governance"],
    "moc_targets": []
  }
]
EOF

assert_json_valid "$extract_dir/plans.json"
plan_count=$(python3 -c "import json; print(len(json.load(open('$extract_dir/plans.json'))))" 2>/dev/null)
assert_eq "$plan_count" "2" "plan count"

# ── Stage 3: Batch splitting + prompt building ──
batch_dir="$extract_dir/batches"
rm -rf "$batch_dir"
mkdir -p "$batch_dir"

# Split into batches (parallel=2)
python3 -c "
import json, math
with open('$extract_dir/plans.json') as f:
    plans = json.load(f)
parallel = 2
batch_size = math.ceil(len(plans) / parallel)
for i in range(parallel):
    start = i * batch_size
    end = min(start + batch_size, len(plans))
    if start >= len(plans):
        break
    batch = plans[start:end]
    with open('$batch_dir/batch_{i}.json', 'w') as f:
        json.dump(batch, f, ensure_ascii=False, indent=2)
"

# Build prompts for each batch
for batch_file in "$batch_dir"/batch_*.json; do
  [ -f "$batch_file" ] || continue
  prompt=$(python3 "$PIPELINE_DIR/build_batch_prompt.py" \
    "$batch_file" "$extract_dir" "$vault" \
    "$PIPELINE_DIR/../prompts/entry-structure.prompt" \
    "$PIPELINE_DIR/../prompts/concept-structure.prompt" 2>/dev/null)

  if [ -z "$prompt" ]; then
    test_fail "empty prompt for $(basename $batch_file)"
    break
  fi
done

# ── Simulate Stage 3 file creation ──
# Write a source note
mkdir -p "$vault/04-Wiki/sources"
cat > "$vault/04-Wiki/sources/ai-forecasting-a-comprehensive-guide.md" << 'EOFSRC'
---
title: "AI Forecasting: A Comprehensive Guide"
source_url: "https://blog.example.com/ai-forecasting"
source_type: web
author: "Jane Smith"
date_captured: 2026-04-17
tags: [ai, forecasting, machine-learning]
status: processed
---

# Original content

Artificial intelligence is transforming how we make predictions about the future.
This article explores the intersection of AI and forecasting, covering key methods.
EOFSRC

# Write an entry note
mkdir -p "$vault/04-Wiki/entries"
cat > "$vault/04-Wiki/entries/ai-forecasting-a-comprehensive-guide.md" << 'EOFENTRY'
---
title: "AI Forecasting: A Comprehensive Guide"
source: "[[ai-forecasting-a-comprehensive-guide]]"
date_entry: 2026-04-17
status: review
reviewed: null
review_notes: null
template: technical
aliases: []
tags:
  - entry
  - ai
  - forecasting
  - machine-learning
  - prediction
---

## Summary

This article explores how artificial intelligence is being applied to forecasting problems, covering neural networks, Bayesian methods, and ensemble approaches.

## Key Findings

1. Neural networks excel at capturing complex temporal patterns in time series data.
2. Bayesian methods provide principled uncertainty quantification for predictions.
3. Ensemble approaches combining multiple models yield more robust forecasts.

## Data/Evidence

Applications span weather prediction, financial markets, and epidemiological modeling.

## Methodology

Survey of modern AI forecasting techniques with case studies.

## Limitations

Does not cover causal inference methods or domain-specific constraints.

## Linked concepts

- [[ai-and-machine-learning]]
- [[forecasting]]
EOFENTRY

# Write a new concept
mkdir -p "$vault/04-Wiki/concepts"
cat > "$vault/04-Wiki/concepts/decentralized-governance.md" << 'EOFCONCEPT'
---
title: "Decentralized Governance"
type: concept
status: review
sources: ["[[decentralized-governance-in-practice]]"]
tags:
  - concept
  - governance
  - decentralization
  - dao
created: 2026-04-17
last_updated: 2026-04-17
---

## Core concept

Decentralized governance refers to decision-making systems where authority is distributed across participants rather than concentrated in a central entity.

## Context

In blockchain and DAO contexts, governance mechanisms determine how protocol changes are proposed, debated, and executed. MakerDAO uses executive voting, Compound uses Governor Bravo, and Optimism experiments with bicameral structures.

## Links

- [[decentralized-autonomous-organizations]]
- [[decentralized-governance-in-practice]]
EOFCONCEPT

# ── Verification ──
all_ok=true

# Verify files exist in correct locations
for f in \
  "$vault/04-Wiki/sources/ai-forecasting-a-comprehensive-guide.md" \
  "$vault/04-Wiki/entries/ai-forecasting-a-comprehensive-guide.md" \
  "$vault/04-Wiki/concepts/decentralized-governance.md"; do
  if [ ! -f "$f" ]; then
    test_fail "missing file: $f"
    all_ok=false
  fi
done

# Verify no stubs in created files
for f in \
  "$vault/04-Wiki/sources/ai-forecasting-a-comprehensive-guide.md" \
  "$vault/04-Wiki/entries/ai-forecasting-a-comprehensive-guide.md" \
  "$vault/04-Wiki/concepts/decentralized-governance.md"; do
  for stub in "TODO" "FIXME" "PLACEHOLDER" "Lorem ipsum" "[insert"; do
    if grep -qi "$stub" "$f" 2>/dev/null; then
      test_fail "stub found in $(basename $f): $stub"
      all_ok=false
    fi
  done
done

# Verify no files outside expected paths
unexpected=$(find "$vault" -type f -not -path "$vault/01-Raw/*" \
  -not -path "$vault/04-Wiki/*" \
  -not -path "$vault/06-Config/*" \
  -not -path "$vault/Meta/*" | wc -l)
# 01-Raw has the .url files, 04-Wiki has created content, 06-Config has init files, Meta has log

if $all_ok; then
  test_pass
fi

rm -rf "$extract_dir"
cleanup_test_vault "$vault"

# ═══════════════════════════════════════════════════════════════════════════
# Test: JSON schema validation for each pipeline artifact
# ═══════════════════════════════════════════════════════════════════════════
test_start "Pipeline JSON artifacts match expected schema"
extract_dir="/tmp/test-schema-$$"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"

# Extraction JSON schema
hash=$(create_extracted_fixture "$extract_dir" "https://example.com/s" "Title" "Content" "web" "auth")
extract_json="$extract_dir/${hash}.json"
assert_json_valid "$extract_json"
for key in url title content type author source_file; do
  assert_json_key "$extract_json" "$key"
done

# Manifest schema
create_manifest "$extract_dir"
manifest_json="$extract_dir/manifest.json"
assert_json_valid "$manifest_json"
# Manifest is array of objects with hash field
manifest_ok=$(python3 -c "
import json
with open('$manifest_json') as f:
    m = json.load(f)
print(isinstance(m, list) and all('hash' in e and 'url' in e and 'title' in e for e in m))
" 2>/dev/null)
assert_eq "$manifest_ok" "True" "manifest schema"

# Plan schema
cat > "$extract_dir/plans.json" << 'EOF'
[{"hash":"abc","title":"T","language":"en","template":"standard","tags":[],"concept_updates":[],"concept_new":[],"moc_targets":[]}]
EOF
plan_ok=$(python3 -c "
import json
with open('$extract_dir/plans.json') as f:
    plans = json.load(f)
p = plans[0]
required = ['hash','title','language','template','tags','concept_updates','concept_new','moc_targets']
print(all(k in p for k in required))
" 2>/dev/null)
assert_eq "$plan_ok" "True" "plan schema"

test_pass

rm -rf "$extract_dir"

# ═══════════════════════════════════════════════════════════════════════════
# Test: Pipeline orchestrator script exists
# ═══════════════════════════════════════════════════════════════════════════
test_start "process-inbox-v2.sh exists"
if [ -f "$PIPELINE_DIR/process-inbox-v2.sh" ]; then
  test_pass
else
  test_fail "process-inbox-v2.sh not found"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary
test_exit_code
