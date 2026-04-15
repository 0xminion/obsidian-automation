#!/usr/bin/env bash
# ============================================================================
# v2.2: Compile Pass — Incremental wiki improvement (Karpathy-style)
# ============================================================================
# Changes from v2.1:
#   - Sources common library (lib/common.sh)
#   - Fixed duplicate Operation 5/7 bug
#   - Added Operation 7: Typed edges construction (edges.tsv)
#   - Added Operation 8: Schema co-evolution (review agents.md)
#   - Git auto-commit after compile
#   - Externalized prompt via load_prompt() (compile-pass.prompt)
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

acquire_lock "compile-pass" || exit 1
setup_directory_structure

log "=== Starting compile pass (v2.2) ==="

# Count notes for reporting
entry_count=$(find "$VAULT_PATH/04-Wiki/entries" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
concept_count=$(find "$VAULT_PATH/04-Wiki/concepts" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
moc_count=$(find "$VAULT_PATH/04-Wiki/mocs" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

log "Running compile pass with agent..."

# Load externalized prompt and substitute placeholders
COMPILE_PROMPT=$(load_prompt "compile-pass")
COMPILE_PROMPT=$(echo "$COMPILE_PROMPT" | sed \
  -e "s|{VAULT_PATH}|$VAULT_PATH|g" \
  -e "s|{ENTRY_COUNT}|$entry_count|g" \
  -e "s|{CONCEPT_COUNT}|$concept_count|g" \
  -e "s|{MOC_COUNT}|$moc_count|g")

if run_with_retry "Wiki compile pass (v2.2)" "$COMPILE_PROMPT"; then
  log "=== Compile pass completed successfully (v2.2) ==="
  auto_commit "compile" "Wiki compile pass ($entry_count entries, $concept_count concepts, $moc_count MoCs)"
  echo "Compile pass complete."
else
  log "=== Compile pass FAILED (v2.2) ==="
  echo "Compile pass failed. Check $LOG_FILE for details."
  exit 1
fi
