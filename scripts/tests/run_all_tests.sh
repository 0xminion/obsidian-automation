#!/usr/bin/env bash
# ============================================================================
# Pipeline Test Runner — Run all tests for the 3-stage pipeline
# ============================================================================
# Usage: ./run_all_tests.sh [test_name...]
#   No args: run all tests
#   With args: run only matching test files (e.g. "stage1" "edge")
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Pipeline Test Suite — 3-Stage Pipeline v2      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# Cleanup stale test artifacts
rm -rf /tmp/test-vault-* /tmp/test-extract-* /tmp/test-prompt-* /tmp/test-batch-* /tmp/test-e2e-* /tmp/test-schema-* /tmp/test-special-* /tmp/test-slash-* /tmp/test-chinese-* /tmp/test-long-* /tmp/test-truncation-* /tmp/test-mixed-* /tmp/test-empty-* /tmp/test-unicode-* /tmp/test-newlines-* /tmp/test-manifest-* 2>/dev/null || true

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
FAILED_NAMES=""

run_suite() {
  local name="$1"
  local script="$2"

  TOTAL_SUITES=$((TOTAL_SUITES + 1))
  echo -e "${BOLD}━━━ Running: $name ━━━${NC}"
  echo ""

  if bash "$script"; then
    PASSED_SUITES=$((PASSED_SUITES + 1))
    echo ""
    echo -e "  ${GREEN}✓ $name PASSED${NC}"
  else
    FAILED_SUITES=$((FAILED_SUITES + 1))
    FAILED_NAMES="${FAILED_NAMES}\n  ✗ $name"
    echo ""
    echo -e "  ${RED}✗ $name FAILED${NC}"
  fi
  echo ""
}

# Determine which tests to run
if [ $# -gt 0 ]; then
  for arg in "$@"; do
    case "$arg" in
      stage1|1)    run_suite "Stage 1: Extract" "$SCRIPT_DIR/test_stage1_extract.sh" ;;
      stage2|2)    run_suite "Stage 2: Plan" "$SCRIPT_DIR/test_stage2_plan.sh" ;;
      stage3|3)    run_suite "Stage 3: Create" "$SCRIPT_DIR/test_stage3_create.sh" ;;
      e2e|end)     run_suite "End-to-End" "$SCRIPT_DIR/test_end_to_end.sh" ;;
      edge)        run_suite "Edge Cases" "$SCRIPT_DIR/test_edge_cases.sh" ;;
      *)
        echo "Unknown test: $arg"
        echo "Valid: stage1, stage2, stage3, e2e, edge"
        exit 1
        ;;
    esac
  done
else
  run_suite "Stage 1: Extract" "$SCRIPT_DIR/test_stage1_extract.sh"
  run_suite "Stage 2: Plan" "$SCRIPT_DIR/test_stage2_plan.sh"
  run_suite "Stage 3: Create" "$SCRIPT_DIR/test_stage3_create.sh"
  run_suite "End-to-End" "$SCRIPT_DIR/test_end_to_end.sh"
  run_suite "Edge Cases" "$SCRIPT_DIR/test_edge_cases.sh"
fi

# Cleanup
rm -rf /tmp/test-vault-* /tmp/test-extract-* /tmp/test-prompt-* /tmp/test-batch-* /tmp/test-e2e-* /tmp/test-schema-* /tmp/test-special-* /tmp/test-slash-* /tmp/test-chinese-* /tmp/test-long-* /tmp/test-truncation-* /tmp/test-mixed-* /tmp/test-empty-* /tmp/test-unicode-* /tmp/test-newlines-* /tmp/test-manifest-* 2>/dev/null || true

# Final summary
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Final Results                                   ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  Suites: $PASSED_SUITES passed / $FAILED_SUITES failed / $TOTAL_SUITES total  ${BOLD}║${NC}"
if [ $FAILED_SUITES -gt 0 ]; then
  echo -e "${BOLD}║${NC}  ${RED}Failed:${NC}                                         ${BOLD}║${NC}"
  echo -e "${BOLD}║${NC}$(echo -e "$FAILED_NAMES" | head -5)"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"

if [ $FAILED_SUITES -gt 0 ]; then
  exit 1
else
  exit 0
fi
