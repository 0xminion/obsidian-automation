#!/usr/bin/env bash
# ============================================================================
# v2.1.0: Stage 2 — Plan Batch (1 agent, semantic concept pre-search)
# ============================================================================#
# Takes extracted content from Stage 1, pre-searches concepts via qmd
# (semantic embedding search with Qwen3-Embedding-0.6B-Q8),
# spawns a single planning agent to produce per-source creation plans.
#
# Usage: ./stage2-plan.sh [--vault PATH]
#
# Input:  /tmp/extracted/manifest.json (from Stage 1)
# Output: /tmp/extracted/plans.json
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

CONCEPTS_DIR="$VAULT_PATH/04-Wiki/concepts"
ENTRIES_DIR="$VAULT_PATH/04-Wiki/entries"
MOCS_DIR="$VAULT_PATH/04-Wiki/mocs"
MANIFEST="/tmp/extracted/manifest.json"
PLANS_OUT="/tmp/extracted/plans.json"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: No manifest found. Run stage1-extract.sh first."
  exit 1
fi

log "=== Stage 2: Plan Batch ==="

# Load manifest early (needed by both dedup and concept search)
manifest_json=$(cat "$MANIFEST")

# ═══════════════════════════════════════════════════════════
# STEP 0: SEMANTIC DEDUP CHECK
# ═══════════════════════════════════════════════════════════
# Before planning, check if any extracted source is a semantic duplicate
# of an existing vault source (same content, different URL).
# Uses content fingerprinting: first 800 chars normalized.

log "Running semantic dedup check against existing sources..."

dedup_json=$(python3 -c "
import json, os, re, sys

def fingerprint(text):
    '''Normalize and extract content fingerprint.'''
    # Strip whitespace, lowercase, take first 800 chars
    normalized = re.sub(r'\s+', ' ', text.lower().strip())[:800]
    return normalized

def jaccard_similarity(fp1, fp2, ngram=3):
    '''Character n-gram Jaccard similarity. O(n) with sets.'''
    if not fp1 or not fp2:
        return 0.0
    ng1 = set(fp1[i:i+ngram] for i in range(len(fp1) - ngram + 1))
    ng2 = set(fp2[i:i+ngram] for i in range(len(fp2) - ngram + 1))
    if not ng1 or not ng2:
        return 0.0
    return len(ng1 & ng2) / len(ng1 | ng2)

# Load manifest
with open('$MANIFEST') as f:
    manifest = json.load(f)

# Build fingerprint index from existing sources
sources_dir = '$VAULT_PATH/04-Wiki/sources'
existing_fps = []
if os.path.isdir(sources_dir):
    for fname in os.listdir(sources_dir):
        if not fname.endswith('.md'):
            continue
        fpath = os.path.join(sources_dir, fname)
        try:
            content = open(fpath).read()
            # Extract body (after frontmatter)
            m = re.match(r'^---\n.*?\n---\n(.*)', content, re.DOTALL)
            body = m.group(1) if m else content
            fp = fingerprint(body)
            if len(fp) > 100:  # Skip empty/stub sources
                existing_fps.append({'name': fname.replace('.md', ''), 'fp': fp})
        except Exception:
            continue

# Check each manifest entry against existing sources
duplicates = []
for entry in manifest:
    entry_fp = fingerprint(entry.get('content', ''))
    if len(entry_fp) < 100:
        continue
    for existing in existing_fps:
        sim = jaccard_similarity(entry_fp, existing['fp'])
        if sim > 0.85:
            duplicates.append({
                'hash': entry['hash'],
                'duplicate_of': existing['name'],
                'similarity': round(sim, 3)
            })
            break

print(json.dumps(duplicates))
" 2>/dev/null) || dedup_json="[]"

# Filter duplicates from manifest
if [ "$dedup_json" != "[]" ] && [ -n "$dedup_json" ]; then
  dup_count=$(echo "$dedup_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  if [ "$dup_count" -gt 0 ]; then
    log "Found $dup_count semantic duplicates — removing from pipeline"
    echo "$dedup_json" >&2  # Log duplicates for debugging

    # Remove duplicate entries from manifest
    manifest_json=$(echo "$manifest_json" | python3 -c "
import json, sys
manifest = json.load(sys.stdin)
dups = json.load(sys.argv[1])
dup_hashes = {d['hash'] for d in dups}
filtered = [e for e in manifest if e['hash'] not in dup_hashes]
print(json.dumps(filtered))
" "$dedup_json" 2>/dev/null) || true
  else
    log "No semantic duplicates found"
  fi
else
  log "No semantic duplicates found"
fi

# ═══════════════════════════════════════════════════════════
# STEP 1: PRE-SEARCH EXISTING CONCEPTS (qmd semantic search)
# ═══════════════════════════════════════════════════════════

# Build existing MoC list (still needed for plan prompt)
moc_list=""
if [ -d "$MOCS_DIR" ]; then
  for mf in "$MOCS_DIR"/*.md; do
    [ -f "$mf" ] || continue
    mname=$(basename "$mf" .md)
    moc_list="$moc_list$mname
"
  done
fi

# Semantic concept matching via qmd (Qwen3-Embedding-0.6B-Q8)
# Falls back to empty matches if qmd unavailable
log "Pre-searching concept matches via qmd (semantic)..."
concept_matches_json=$(qmd_batch_concept_search "$manifest_json" 2>/dev/null)

# Validate output
if [ -z "$concept_matches_json" ] || ! echo "$concept_matches_json" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
  log "WARN: qmd concept search returned invalid output, falling back to empty matches"
  concept_matches_json=$(python3 -c "
import json, sys
with open('$MANIFEST') as f:
    manifest = json.load(f)
print(json.dumps({e['hash']: [] for e in manifest}))
")
fi

echo "$concept_matches_json" > /tmp/extracted/concept_matches.json
matched_count=$(echo "$concept_matches_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
total = sum(len(v) for v in d.values())
print(total)
" 2>/dev/null || echo "0")
log "Concept matching complete: $matched_count total matches across all sources"

# ═══════════════════════════════════════════════════════════
# STEP 2: BUILD SLIM PROMPT (no extraction, no search)
# ═══════════════════════════════════════════════════════════

# Load templates (W7 fix: include common-instructions)
COMMON_INSTRUCTIONS=$(cat "$SCRIPT_DIR/../prompts/common-instructions.prompt" 2>/dev/null || echo "")

today=$(date +%Y-%m-%d)

plan_prompt=$(python3 -c "
import json, sys, os
from datetime import date

with open('$MANIFEST') as f:
    manifest = json.load(f)

with open('/tmp/extracted/concept_matches.json') as f:
    concept_matches = json.load(f)

common = open('$SCRIPT_DIR/../prompts/common-instructions.prompt').read() if os.path.exists('$SCRIPT_DIR/../prompts/common-instructions.prompt') else ''

concept_count = len([f for f in os.listdir('$CONCEPTS_DIR') if f.endswith('.md')]) if os.path.isdir('$CONCEPTS_DIR') else 0

sources_block = ''
for i, entry in enumerate(manifest):
    h = entry['hash']
    title = entry.get('title', 'Untitled')[:120]
    content_preview = entry.get('content', '')[:300].replace(chr(10), ' ')
    source_type = entry.get('type', 'web')
    author = entry.get('author', 'unknown')
    matches = concept_matches.get(h, [])

    sources_block += f'''
---
Source {i+1}:
  hash: {h}
  title: {title}
  type: {source_type}
  author: {author}
  content_preview: {content_preview}
  concept_matches: {json.dumps(matches)}
'''

prompt = f'''{common}

You are a planning agent for an Obsidian wiki pipeline. For each extracted source below, output a creation plan as JSON.

VAULT CONCEPTS DIRECTORY: {concept_count} existing concepts

SOURCES TO PLAN:{sources_block}

---

For EACH source, output a JSON object in a JSON array. Schema per source:

{{\"hash\": \"<source hash>\", \"title\": \"<ACTUAL content title for filename — NOT URL slug, NOT platform name>\", \"language\": \"en\" or \"zh\", \"template\": \"standard\" or \"technical\" or \"chinese\", \"tags\": [\"topic-specific tags in English\"], \"concept_updates\": [\"existing concept names to update\"], \"concept_new\": [\"new concept names to create\"], \"moc_targets\": [\"MoC names this source belongs to\"]}}

RULES:
- title: Use the content REAL title. Tweet → first meaningful topic. Blog → article title. YouTube → video title.
- NEVER use: \"Tweet - user - ID\", \"Blog - slug\", \"YouTube - VIDEO_ID\", URL slugs
- language: Chinese content → \"zh\", everything else → \"en\"
- template: Data/methodology/findings → \"technical\". Narrative/philosophical → \"standard\". Chinese → \"chinese\".
- tags: Topic-specific English only. NO: x.com, tweet, source, url
- concept_matches are pre-found via semantic search — rank-sorted by relevance, confirm which are real matches vs tangential
- concept_new: only if genuinely new concept
- Be concise. Output ONLY the JSON array, no explanation.

OUTPUT ONLY VALID JSON.'''

print(prompt)
")

# Save prompt for debugging
echo "$plan_prompt" > /tmp/extracted/plan_prompt.md
prompt_size=${#plan_prompt}
log "Plan prompt size: $prompt_size chars (vs ~18K in old pipeline)"

# ═══════════════════════════════════════════════════════════
# STEP 3: RUN PLANNING AGENT
# ═══════════════════════════════════════════════════════════

log "Spawning planning agent..."
plan_result=0
timeout 600 "$AGENT_CMD" chat -q "$plan_prompt" -Q > /tmp/extracted/plan_output.txt 2>> "$LOG_FILE" || plan_result=$?

if [ $plan_result -ne 0 ]; then
  log "Plan agent failed (exit $plan_result), retrying..."
  sleep 5
  plan_result=0
  timeout 600 "$AGENT_CMD" chat -q "$plan_prompt" -Q > /tmp/extracted/plan_output.txt 2>> "$LOG_FILE" || plan_result=$?
fi

if [ $plan_result -ne 0 ]; then
  log "Plan agent failed twice. Aborting."
  exit 1
fi

# ═══════════════════════════════════════════════════════════
# STEP 4: PARSE PLANS OUTPUT
# ═══════════════════════════════════════════════════════════

log "Parsing plan output..."

python3 -c "
import json, re, sys

with open('/tmp/extracted/plan_output.txt') as f:
    raw = f.read()

# Strip ANSI escape codes and box-drawing characters
raw_clean = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', raw)
raw_clean = re.sub(r'[╭╮╰╯│─╮╰╯├┤┬┴┼]', '', raw_clean)

# Try to find JSON array first (fast path)
json_match = re.search(r'\[.*\]', raw_clean, re.DOTALL)
if json_match:
    try:
        plans = json.loads(json_match.group())
        with open('/tmp/extracted/plans.json', 'w') as f:
            json.dump(plans, f, ensure_ascii=False, indent=2)
        print(f'Parsed {len(plans)} plans')
        sys.exit(0)
    except json.JSONDecodeError as e:
        print(f'JSON array parse error: {e}', file=sys.stderr)
        # Fall through to object-by-object parsing

# Object-by-object parsing with partial failure recovery
plans = []
failed_hashes = []
depth = 0
start = -1
for i, c in enumerate(raw_clean):
    if c == '{':
        if depth == 0:
            start = i
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0 and start >= 0:
            try:
                obj = json.loads(raw_clean[start:i+1])
                if 'hash' in obj:
                    plans.append(obj)
                else:
                    # Object without hash — log but don't fail
                    print(f'WARN: Parsed object without hash field, skipping', file=sys.stderr)
            except json.JSONDecodeError as e:
                # Partial failure — log and continue
                snippet = raw_clean[start:min(start+100, i+1)]
                print(f'WARN: Failed to parse JSON object: {e}', file=sys.stderr)
                print(f'  Snippet: {snippet[:80]}...', file=sys.stderr)
            except Exception as e:
                print(f'WARN: Unexpected error parsing object: {e}', file=sys.stderr)
            start = -1

if plans:
    with open('/tmp/extracted/plans.json', 'w') as f:
        json.dump(plans, f, ensure_ascii=False, indent=2)
    print(f'Parsed {len(plans)} plans (object-by-object)')
    if failed_hashes:
        print(f'WARNING: {len(failed_hashes)} plans failed to parse, continuing with partial results', file=sys.stderr)
    sys.exit(0)

print('ERROR: Could not parse any plans from agent output', file=sys.stderr)
print(f'Raw output (first 500 chars): {raw[:500]}', file=sys.stderr)
sys.exit(1)"

parse_result=$?

if [ $parse_result -ne 0 ]; then
  log "ERROR: Failed to parse any plans from agent output"
  exit 1
fi

plan_count=$(python3 -c "import json; print(len(json.load(open('/tmp/extracted/plans.json'))))")
manifest_count=$(python3 -c "import json; print(len(json.load(open('/tmp/extracted/manifest.json'))))" 2>/dev/null || echo "?")

if [ "$plan_count" -lt "$manifest_count" ]; then
  log "WARNING: Parsed $plan_count plans from $manifest_count sources — some may have failed"
fi

log "=== Stage 2 complete: $plan_count plans generated ==="

echo "Plans: $plan_count"
exit 0
