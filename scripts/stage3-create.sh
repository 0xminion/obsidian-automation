#!/usr/bin/env bash
# ============================================================================
# v2.1.0: Stage 3 — Create Batch (parallel write-only agents)
# ============================================================================#
# Takes plans + extracted content from Stage 2, spawns parallel agents
# to write Source, Entry, Concept, MoC files. No extraction, no searching.
# Concept convergence uses pre-fetched qmd semantic matches.
#
# Usage: ./stage3-create.sh [--vault PATH] [--parallel N]
#
# Input:  /tmp/extracted/plans.json + /tmp/extracted/*.json (from Stage 1+2)
# Output: Files written to vault, inbox archived, wiki-index updated
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

PARALLEL="${PARALLEL:-3}"
PLANS="/tmp/extracted/plans.json"
EXTRACT_DIR="/tmp/extracted"

ENTRY_TEMPLATE="$SCRIPT_DIR/../prompts/entry-structure.prompt"
CONCEPT_TEMPLATE="$SCRIPT_DIR/../prompts/concept-structure.prompt"
COMMON_INSTRUCTIONS="$SCRIPT_DIR/../prompts/common-instructions.prompt"

if [ ! -f "$PLANS" ]; then
  echo "ERROR: No plans found. Run stage2-plan.sh first."
  exit 1
fi

# C6 fix: validate PARALLEL is numeric
if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || [ "$PARALLEL" -lt 1 ]; then
  echo "ERROR: PARALLEL must be a positive integer, got: $PARALLEL"
  exit 1
fi

log "=== Stage 3: Create Batch (parallel=$PARALLEL) ==="

# ═══════════════════════════════════════════════════════════
# SPLIT PLANS INTO BATCHES
# ═══════════════════════════════════════════════════════════

plan_count=$(python3 -c "import json; print(len(json.load(open('$PLANS'))))")
log "Total plans: $plan_count"

if [ "$plan_count" -eq 0 ]; then
  log "No plans to process"
  exit 0
fi

batch_dir="/tmp/extracted/batches"
rm -rf "$batch_dir"
mkdir -p "$batch_dir"

python3 -c "
import json, math, os

with open('$PLANS') as f:
    plans = json.load(f)

parallel = int(os.environ.get('PARALLEL', '3'))
batch_size = math.ceil(len(plans) / parallel)

for i in range(parallel):
    start = i * batch_size
    end = min(start + batch_size, len(plans))
    if start >= len(plans):
        break
    batch = plans[start:end]
    with open(f'$batch_dir/batch_{i}.json', 'w') as f:
        json.dump(batch, f, ensure_ascii=False, indent=2)
    print(f'Batch {i}: {len(batch)} plans (indices {start}-{end-1})')
"

# ═══════════════════════════════════════════════════════════
# CONCEPT CONVERGENCE SEARCH (qmd, per-plan)
# ═══════════════════════════════════════════════════════════
# For each plan, search existing concepts to help the agent find
# near-duplicates before creating new concepts.

log "Running concept convergence search via qmd..."
convergence_dir="/tmp/extracted/convergence"
rm -rf "$convergence_dir"
mkdir -p "$convergence_dir"

for convergence_batch in "$batch_dir"/batch_*.json; do
  [ -f "$convergence_batch" ] || continue
  conv_batch_name=$(basename "$convergence_batch" .json)

  python3 -c "
import json, os, subprocess

qmd_cmd = os.environ.get('QMD_CMD', 'qmd')
collection = os.environ.get('QMD_COLLECTION', 'concepts')

with open('$convergence_batch') as f:
    plans = json.load(f)

batch_convergence = {}
for plan in plans:
    h = plan['hash']
    concept_new = plan.get('concept_new', [])
    concept_updates = plan.get('concept_updates', [])

    extract_file = os.path.join('$EXTRACT_DIR', f'{h}.json')
    content_preview = ''
    if os.path.exists(extract_file):
        with open(extract_file) as ef:
            ext = json.load(ef)
            content_preview = ext.get('content', '')[:500]

    title = plan.get('title', '')
    query_parts = [title] + concept_new + concept_updates + [content_preview]
    query = ' '.join(p for p in query_parts if p)[:800]

    if not query.strip():
        batch_convergence[h] = []
        continue

    try:
        result = subprocess.run(
            [qmd_cmd, 'query', query, '--json', '-n', '5', '--min-score', '0.2',
             '-c', collection, '--no-rerank'],
            capture_output=True, text=True, timeout=300
        )
        # Strip cmake/Vulkan noise from stdout — find actual JSON array start
        stdout_clean = result.stdout
        for marker in ['[\n  {', '[\n{']:
            idx = stdout_clean.find(marker)
            if idx >= 0:
                try:
                    json.loads(stdout_clean[idx:].rstrip())
                    stdout_clean = stdout_clean[idx:].rstrip()
                    break
                except json.JSONDecodeError:
                    continue
        else:
            try:
                json.loads(stdout_clean.strip())
                stdout_clean = stdout_clean.strip()
            except Exception:
                stdout_clean = '[]'

        if result.returncode == 0 and stdout_clean.startswith('['):
            qmd_results = json.loads(stdout_clean)
            matches = []
            for r in qmd_results:
                f = r.get('file', '')
                name = f.split('/')[-1].replace('.md', '') if '/' in f else f.replace('.md', '')
                score = r.get('score', 0)
                if name:
                    matches.append({'concept': name, 'score': round(score, 3)})
            batch_convergence[h] = matches
        else:
            batch_convergence[h] = []
    except Exception:
        batch_convergence[h] = []

out_file = os.path.join('$convergence_dir', '${conv_batch_name}.json')
with open(out_file, 'w') as f:
    json.dump(batch_convergence, f, indent=2, ensure_ascii=False)
total = sum(len(v) for v in batch_convergence.values())
print(f'  {conv_batch_name}: {total} convergence matches')
" 2>/dev/null || log "WARN: convergence search failed for $conv_batch_name"
done
log "Concept convergence search complete"

# ═══════════════════════════════════════════════════════════
# SPAWN PARALLEL AGENTS
# ═══════════════════════════════════════════════════════════

agent_pids=()
agent_batch_files=()  # W4 fix: store batch filenames alongside PIDs

for batch_file in "$batch_dir"/batch_*.json; do
  [ -f "$batch_file" ] || continue

  batch_name=$(basename "$batch_file" .json)
  output_file="/tmp/extracted/${batch_name}_output.txt"

  # Build prompt using Python helper (includes concept convergence data)
  log "Building prompt for $batch_name..."
  convergence_file="$convergence_dir/${batch_name}.json"
  if [ ! -f "$convergence_file" ]; then
    convergence_file=""
  fi
  batch_prompt=$(python3 "$SCRIPT_DIR/build_batch_prompt.py" \
    "$batch_file" "$EXTRACT_DIR" "$VAULT_PATH" "$ENTRY_TEMPLATE" "$CONCEPT_TEMPLATE" "$COMMON_INSTRUCTIONS" "$convergence_file")

  echo "$batch_prompt" > "/tmp/extracted/${batch_name}_prompt.md"
  prompt_size=${#batch_prompt}
  log "Spawning agent for $batch_name (prompt: $prompt_size chars)..."

  # Spawn agent in background
  (
    result=0
    timeout 900 "$AGENT_CMD" chat -q "$batch_prompt" -Q > "$output_file" 2>> "$LOG_FILE" || result=$?
    echo "$result" > "/tmp/extracted/${batch_name}_exitcode"
  ) &

  agent_pids+=($!)
  agent_batch_files+=("$batch_file")  # W4: store filename with PID
  log "Agent $batch_name started (PID ${agent_pids[-1]})"
done

# ═══════════════════════════════════════════════════════════
# WAIT FOR ALL AGENTS
# ═══════════════════════════════════════════════════════════

log "Waiting for ${#agent_pids[@]} agents to complete..."
failed_agents=0
successful_batches=()

for i in "${!agent_pids[@]}"; do
  pid="${agent_pids[$i]}"
  batch_file="${agent_batch_files[$i]}"  # W4: use stored filename
  batch_name=$(basename "$batch_file" .json)

  if wait "$pid"; then
    log "Agent $batch_name completed successfully"
    successful_batches+=("$batch_name")
  else
    exit_code=$(cat "/tmp/extracted/${batch_name}_exitcode" 2>/dev/null || echo "?")
    log "Agent $batch_name FAILED (exit $exit_code)"
    failed_agents=$((failed_agents + 1))
  fi
done

# ═══════════════════════════════════════════════════════════
# POST-PROCESSING
# ═══════════════════════════════════════════════════════════

log "Post-processing..."

# Rebuild wiki-index
if [ "$plan_count" -ge 1 ]; then
  log "Rebuilding wiki-index..."
  bash "$SCRIPT_DIR/reindex.sh" 2>> "$LOG_FILE" || log "WARN: reindex failed"
fi

# Log to vault
log_entry="## [$(date +%Y-%m-%d)] ingest | batch ($plan_count sources)
- Pipeline: v2 (3-stage)
- Sources processed: $plan_count
- Failed agents: $failed_agents
"
echo "$log_entry" >> "$VAULT_PATH/06-Config/log.md" 2>/dev/null || true

# C7 fix: only archive URLs that were successfully processed by an agent
# Build set of successfully processed hashes
successful_hashes=$(python3 -c "
import json, os
hashes = set()
batches_dir = '$batch_dir'
extract_dir = '$EXTRACT_DIR'
for bn in '$(IFS=,; echo "${successful_batches[*]}")'.split(','):
    if not bn:
        continue
    bf = os.path.join(batches_dir, f'{bn}.json')
    if os.path.exists(bf):
        with open(bf) as f:
            for plan in json.load(f):
                hashes.add(plan['hash'])
print(' '.join(hashes))
" 2>/dev/null || echo "")

log "Archiving inbox files (only successfully processed)..."
archived=0
for file in "$VAULT_PATH/01-Raw"/*.url; do
  [ -f "$file" ] || continue
  url=$(cat "$file" | tr -d '\r\n')
  url_hash=$(echo -n "$url" | md5sum | cut -c1-12)

  # Only archive if this hash was in a successful batch
  if echo "$successful_hashes" | grep -q "$url_hash"; then
    mkdir -p "$VAULT_PATH/08-Archive-Raw"
    mv "$file" "$VAULT_PATH/08-Archive-Raw/" 2>/dev/null && archived=$((archived + 1))
  else
    log "SKIP archive (agent failed or not in successful batch): $file"
  fi
done
log "Archived $archived inbox files"

# Sync vault
log "Syncing vault..."
ob sync --path "$VAULT_PATH" >> "$LOG_FILE" 2>&1 || log "WARN: vault sync failed"

log "=== Stage 3 complete: $plan_count sources, $failed_agents failed ==="
echo "Created: $((plan_count - failed_agents)) | Failed: $failed_agents"

# I6 fix: bounds check on output
if [ "$failed_agents" -gt "$plan_count" ]; then
  failed_agents="$plan_count"
fi

exit 0
