#!/usr/bin/env bash
# ============================================================================
# v2.1.0: Process Inbox v2 — 3-stage pipeline orchestrator
# ============================================================================
# Replaces the monolithic process-inbox.sh with a staged architecture:
#   Stage 1: Extract (shell, no agent) — ~10s for 16 URLs
#   Stage 2: Plan   (1 agent, batched) — semantic concept pre-search + plan
#   Stage 3: Create (N agents, parallel) — write files + concept convergence
#
# Concept matching uses qmd + Qwen3-Embedding-0.6B-Q8 (semantic search).
# Run scripts/setup-qmd.sh to initialize the concept index.
#
# Usage:
#   ./process-inbox-v2.sh [--vault PATH] [--parallel N] [--dry-run] [--review] [--resume]
#
# Benefits over v1:
#   - Extraction is shell-only (never touches LLM)
#   - Concept search is semantic (qmd embeddings, not grep)
#   - Per-agent prompt: ~5K chars (vs ~18K in v1)
#   - Parallelizable: 3 agents × 6 sources = 18 sources/round
#   - 900s timeout per agent (vs 600s in v1)
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ═══════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════

PARALLEL="${PARALLEL:-3}"
DRY_RUN=false

# Parse args
REVIEW_MODE=false
RESUME_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault)    VAULT_PATH="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --review)   REVIEW_MODE=true; shift ;;
    --resume)   RESUME_MODE=true; shift ;;
    --help|-h)
      echo "Usage: ./process-inbox-v2.sh [--vault PATH] [--parallel N] [--dry-run] [--review] [--resume]"
      echo "  --review  Run stages 1+2, save plans to vault for manual review"
      echo "  --resume  Skip stages 1+2, use reviewed plans from vault"
      exit 0 ;;
    *)          echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --review and --resume are mutually exclusive
if $REVIEW_MODE && $RESUME_MODE; then
  echo "ERROR: --review and --resume are mutually exclusive"
  exit 1
fi

# ═══════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════

# I5 fix: validate VAULT_PATH before inbox check
if [ ! -d "$VAULT_PATH" ]; then
  echo "ERROR: Vault path does not exist: $VAULT_PATH"
  exit 1
fi

if [ ! -d "$VAULT_PATH/01-Raw" ]; then
  echo "ERROR: Vault missing 01-Raw/ inbox directory: $VAULT_PATH/01-Raw"
  exit 1
fi

# W2 fix: acquire lock to prevent concurrent runs
if ! acquire_lock "process-inbox-v2"; then
  echo "ERROR: Another pipeline run is in progress"
  echo "If stale, run: rmdir /tmp/obsidian-process-inbox-v2-*.lock"
  exit 1
fi

inbox_count=$(find "$VAULT_PATH/01-Raw" -name "*.url" 2>/dev/null | wc -l)

if [ "$inbox_count" -eq 0 ]; then
  echo "Inbox is empty. Nothing to process."
  exit 0
fi

echo "╔══════════════════════════════════════════════╗"
echo "║  Process Inbox v2 — 3-Stage Pipeline        ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Inbox:  $inbox_count URLs                       ║"
echo "║  Vault:  $VAULT_PATH"
echo "║  Parallel agents: $PARALLEL"
echo "╚══════════════════════════════════════════════╝"
echo ""

if $DRY_RUN; then
  echo "DRY RUN — would process $inbox_count URLs"
  echo "  Stage 1: Shell extraction"
  echo "  Stage 2: Plan agent (~3K prompt)"
  echo "  Stage 3: $PARALLEL parallel create agents (~5K prompt each)"
  exit 0
fi

# Clean up stale extraction data
if ! $RESUME_MODE; then
  rm -rf /tmp/extracted
fi
mkdir -p /tmp/extracted

# Initialize timing variables (set before conditional to avoid unbound var under set -u)
stage1_start=$(date +%s)
stage2_start=$(date +%s)
stage1_duration=0
stage2_duration=0

# ═══════════════════════════════════════════════════════════
# RESUME MODE: Load reviewed plans from vault
# ═══════════════════════════════════════════════════════════

if $RESUME_MODE; then
  REVIEW_FILE="$VAULT_PATH/07-WIP/plans-review.json"
  if [ ! -f "$REVIEW_FILE" ]; then
    echo "ERROR: No reviewed plans found at $REVIEW_FILE"
    echo "Run with --review first to generate plans for review."
    exit 1
  fi

  plan_count=$(python3 -c "import json; print(len(json.load(open('$REVIEW_FILE'))))")
  echo ""
  echo "━━━ Resuming from reviewed plans ($plan_count plans) ━━━"

  cp "$REVIEW_FILE" /tmp/extracted/plans.json

  # Stage 3 needs extraction data — verify it exists
  if [ ! -f /tmp/extracted/manifest.json ]; then
    echo "ERROR: Extraction data missing. Cannot resume without Stage 1 output."
    echo "Run the full pipeline first (without --resume)."
    exit 1
  fi

  # Skip to Stage 3 (timing vars already initialized above)
fi

# ═══════════════════════════════════════════════════════════
# STAGE 1: EXTRACT (shell, no agent) — skipped in --resume
# ═══════════════════════════════════════════════════════════

if ! $RESUME_MODE; then

echo ""
echo "━━━ Stage 1/3: Extract ━━━"
stage1_start=$(date +%s)

bash "$SCRIPT_DIR/stage1-extract.sh" 2>&1 | tee -a "$LOG_FILE"
stage1_result=${PIPESTATUS[0]}

stage1_duration=$(( $(date +%s) - stage1_start ))

if [ $stage1_result -ne 0 ]; then
  echo "ERROR: Stage 1 failed"
  exit 1
fi

echo "Stage 1 complete: ${stage1_duration}s"

# ═══════════════════════════════════════════════════════════
# STAGE 2: PLAN (1 agent, concept pre-search) — skipped in --resume
# ═══════════════════════════════════════════════════════════

echo ""
echo "━━━ Stage 2/3: Plan ━━━"
stage2_start=$(date +%s)

bash "$SCRIPT_DIR/stage2-plan.sh" 2>&1 | tee -a "$LOG_FILE"
stage2_result=${PIPESTATUS[0]}

stage2_duration=$(( $(date +%s) - stage2_start ))

if [ $stage2_result -ne 0 ]; then
  echo "ERROR: Stage 2 failed"
  exit 1
fi

echo "Stage 2 complete: ${stage2_duration}s"

fi  # end if ! RESUME_MODE

# ═══════════════════════════════════════════════════════════
# REVIEW GATE (optional — pauses for plan review)
# ═══════════════════════════════════════════════════════════

if $REVIEW_MODE; then
  REVIEW_FILE="$VAULT_PATH/07-WIP/plans-review.json"
  mkdir -p "$VAULT_PATH/07-WIP"
  cp /tmp/extracted/plans.json "$REVIEW_FILE"

  plan_count=$(python3 -c "import json; print(len(json.load(open('$REVIEW_FILE'))))")

  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Review Mode — Plans Ready for Inspection    ║"
  echo "╠══════════════════════════════════════════════╣"
  echo "║                                              ║"
  echo "║  Plans saved to: $REVIEW_FILE"
  echo "║  Count: $plan_count plans"
  echo "║                                              ║"
  echo "║  Review and edit the plans, then run:        ║"
  echo "║  ./process-inbox-v2.sh --resume              ║"
  echo "║                                              ║"
  echo "║  Each plan has: hash, title, language,       ║"
  echo "║  template, tags, concept_updates,            ║"
  echo "║  concept_new, moc_targets                    ║"
  echo "║                                              ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""

  exit 0
fi

# ═══════════════════════════════════════════════════════════
# STAGE 3: CREATE (N parallel agents)
# ═══════════════════════════════════════════════════════════

echo ""
echo "━━━ Stage 3/3: Create (parallel=$PARALLEL) ━━━"
stage3_start=$(date +%s)

PARALLEL="$PARALLEL" bash "$SCRIPT_DIR/stage3-create.sh" 2>&1 | tee -a "$LOG_FILE"
stage3_result=${PIPESTATUS[0]}

stage3_duration=$(( $(date +%s) - stage3_start ))

if [ $stage3_result -ne 0 ]; then
  echo "WARNING: Stage 3 had failures"
fi

echo "Stage 3 complete: ${stage3_duration}s"

# ═══════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════

total_duration=$(( $(date +%s) - stage1_start ))

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Pipeline Complete                           ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Stage 1 (Extract): ${stage1_duration}s"
echo "║  Stage 2 (Plan):    ${stage2_duration}s"
echo "║  Stage 3 (Create):  ${stage3_duration}s"
echo "║  Total:             ${total_duration}s"
echo "╚══════════════════════════════════════════════╝"

exit 0
