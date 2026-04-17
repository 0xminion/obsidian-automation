#!/usr/bin/env bash
# ============================================================================
# v2.0.2: Stage 2 — Plan Batch (1 agent, concept pre-search)
# ============================================================================
# Takes extracted content from Stage 1, pre-searches concepts via grep,
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

# ═══════════════════════════════════════════════════════════
# STEP 1: PRE-SEARCH EXISTING CONCEPTS (grep, no agent)
# ═══════════════════════════════════════════════════════════

# Build keyword index from existing concepts
log "Building concept keyword index..."
concept_keywords=$(mktemp)
trap 'rm -f "$concept_keywords"' EXIT  # I3 fix: cleanup on exit

if [ -d "$CONCEPTS_DIR" ]; then
  for cf in "$CONCEPTS_DIR"/*.md; do
    [ -f "$cf" ] || continue
    cname=$(basename "$cf" .md)
    {
      echo "$cname"
      head -30 "$cf" | grep -v '^---' | grep -v '^#' | head -5
    } >> "$concept_keywords"
  done
fi

concept_count=$(wc -l < "$concept_keywords")
log "Indexed $concept_count concept entries for search"

# Build existing MoC list
moc_list=""
if [ -d "$MOCS_DIR" ]; then
  for mf in "$MOCS_DIR"/*.md; do
    [ -f "$mf" ] || continue
    mname=$(basename "$mf" .md)
    moc_list="$moc_list$mname
"
  done
fi

# For each extracted source, find matching concepts
log "Pre-searching concept matches per source..."
concept_matches_json=$(python3 -c "
import json, sys, os

with open('$MANIFEST') as f:
    manifest = json.load(f)

concept_dir = '$CONCEPTS_DIR'
concept_files = []
if os.path.isdir(concept_dir):
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

print(json.dumps(matches))
")

echo "$concept_matches_json" > /tmp/extracted/concept_matches.json
log "Concept matching complete"

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
- concept_matches are pre-found — confirm which are real matches vs false positives
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

# Try to find JSON array
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

# Try individual JSON objects by brace depth
plans = []
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
            except:
                pass
            start = -1

if plans:
    with open('/tmp/extracted/plans.json', 'w') as f:
        json.dump(plans, f, ensure_ascii=False, indent=2)
    print(f'Parsed {len(plans)} plans (object-by-object)')
    sys.exit(0)

print('ERROR: Could not parse any plans from agent output', file=sys.stderr)
print(f'Raw output (first 500 chars): {raw[:500]}', file=sys.stderr)
sys.exit(1)"

if [ $? -ne 0 ]; then
  log "ERROR: Failed to parse plans from agent output"
  exit 1
fi

plan_count=$(python3 -c "import json; print(len(json.load(open('/tmp/extracted/plans.json'))))")
log "=== Stage 2 complete: $plan_count plans generated ==="

echo "Plans: $plan_count"
exit 0
