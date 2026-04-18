#!/usr/bin/env bash
# ============================================================================
# Shared test helpers for pipeline tests
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Counters
_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0
_CURRENT_TEST=""
_FAILURES=""

# ── Test Framework ──────────────────────────────────────────────────────────

test_start() {
  _CURRENT_TEST="$1"
  _TESTS_RUN=$((_TESTS_RUN + 1))
  echo -n "  TEST: $_CURRENT_TEST ... "
}

test_pass() {
  _TESTS_PASSED=$((_TESTS_PASSED + 1))
  echo -e "${GREEN}PASS${NC}"
}

test_fail() {
  local msg="${1:-}"
  _TESTS_FAILED=$((_TESTS_FAILED + 1))
  echo -e "${RED}FAIL${NC}"
  if [ -n "$msg" ]; then
    echo "         $msg"
  fi
  _FAILURES="${_FAILURES}\n  ✗ ${_CURRENT_TEST}: ${msg}"
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="${3:-values}"
  if [ "$actual" = "$expected" ]; then
    return 0
  else
    test_fail "$label: expected '$expected', got '$actual'"
    return 1
  fi
}

assert_ne() {
  local actual="$1"
  local not_expected="$2"
  local label="${3:-values}"
  if [ "$actual" != "$not_expected" ]; then
    return 0
  else
    test_fail "$label: expected NOT '$not_expected', got '$actual'"
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="${3:-content}"
  if echo "$haystack" | grep -qF "$needle"; then
    return 0
  else
    test_fail "$label: expected to contain '$needle'"
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="${3:-content}"
  if ! echo "$haystack" | grep -qF "$needle"; then
    return 0
  else
    test_fail "$label: expected NOT to contain '$needle'"
    return 1
  fi
}

assert_file_exists() {
  local path="$1"
  if [ -f "$path" ]; then
    return 0
  else
    test_fail "file does not exist: $path"
    return 1
  fi
}

assert_file_not_exists() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 0
  else
    test_fail "file should not exist: $path"
    return 1
  fi
}

assert_dir_not_exists() {
  local path="$1"
  if [ ! -d "$path" ]; then
    return 0
  else
    test_fail "dir should not exist: $path"
    return 1
  fi
}

assert_gt() {
  local actual="$1"
  local threshold="$2"
  local label="${3:-value}"
  if [ "$actual" -gt "$threshold" ] 2>/dev/null; then
    return 0
  else
    test_fail "$label: expected > $threshold, got '$actual'"
    return 1
  fi
}

assert_json_valid() {
  local file="$1"
  if python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
    return 0
  else
    test_fail "invalid JSON: $file"
    return 1
  fi
}

assert_json_key() {
  local file="$1"
  local key="$2"
  local val
  val=$(python3 -c "import json; print(json.load(open('$file')).get('$key', '__MISSING__'))" 2>/dev/null)
  if [ "$val" != "__MISSING__" ]; then
    return 0
  else
    test_fail "JSON missing key '$key' in $file"
    return 1
  fi
}

assert_no_stubs() {
  local file="$1"
  local stubs=("TODO" "FIXME" "PLACEHOLDER" "TBD" "Lorem ipsum" "[insert" "Content goes here" "Write your" "Add content")
  for stub in "${stubs[@]}"; do
    if grep -qi "$stub" "$file" 2>/dev/null; then
      test_fail "stub text found in $file: '$stub'"
      return 1
    fi
  done
  return 0
}

# ── Vault Setup ─────────────────────────────────────────────────────────────

create_test_vault() {
  local vault_dir
  vault_dir=$(mktemp -d /tmp/test-vault-XXXXX)

  # Create standard vault structure
  mkdir -p "$vault_dir/01-Raw"
  mkdir -p "$vault_dir/02-Clippings"
  mkdir -p "$vault_dir/03-Queries"
  mkdir -p "$vault_dir/04-Wiki/entries"
  mkdir -p "$vault_dir/04-Wiki/concepts"
  mkdir -p "$vault_dir/04-Wiki/mocs"
  mkdir -p "$vault_dir/04-Wiki/sources"
  mkdir -p "$vault_dir/05-Outputs/answers"
  mkdir -p "$vault_dir/05-Outputs/visualizations"
  mkdir -p "$vault_dir/06-Config"
  mkdir -p "$vault_dir/07-WIP"
  mkdir -p "$vault_dir/08-Archive-Raw"
  mkdir -p "$vault_dir/09-Archive-Queries"
  mkdir -p "$vault_dir/Meta/Scripts"
  mkdir -p "$vault_dir/Meta/Templates"

  # Initialize config files
  echo "# Wiki Index" > "$vault_dir/06-Config/wiki-index.md"
  echo -e "source\ttarget\ttype\tdescription" > "$vault_dir/06-Config/edges.tsv"
  echo "# Tag Registry" > "$vault_dir/06-Config/tag-registry.md"
  echo "# Wiki Activity Log" > "$vault_dir/06-Config/log.md"
  touch "$vault_dir/06-Config/url-index.tsv"

  echo "$vault_dir"
}

cleanup_test_vault() {
  local vault_dir="$1"
  if [[ "$vault_dir" == /tmp/test-vault-* ]]; then
    rm -rf "$vault_dir"
  fi
}

# ── URL Inbox Helpers ───────────────────────────────────────────────────────

add_url_to_inbox() {
  local vault_dir="$1"
  local url="$2"
  local slug
  # Generate a unique filename from the URL
  slug=$(echo "$url" | sed 's|https\?://||; s|/|-|g; s|[?#]|-|g; s|\.|-|g; s|--*|-|g; s|-$||')
  # Ensure uniqueness with a counter if needed
  local target="$vault_dir/01-Raw/${slug}.url"
  local counter=1
  while [ -f "$target" ]; do
    target="$vault_dir/01-Raw/${slug}-${counter}.url"
    counter=$((counter + 1))
  done
  echo -n "$url" > "$target"
}

# ── Extraction Fixture Helpers ──────────────────────────────────────────────

create_extracted_fixture() {
  local extract_dir="$1"
  local url="$2"
  local title="$3"
  local content="$4"
  local source_type="${5:-web}"
  local author="${6:-unknown}"

  mkdir -p "$extract_dir"
  local url_hash
  url_hash=$(echo -n "$url" | md5sum | cut -c1-12)

  python3 -c "
import json, sys
data = {
    'url': sys.argv[1],
    'title': sys.argv[2],
    'content': sys.argv[3],
    'type': sys.argv[4],
    'author': sys.argv[5],
    'source_file': 'test.url'
}
with open(sys.argv[6], 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
" "$url" "$title" "$content" "$source_type" "$author" "$extract_dir/${url_hash}.json"

  echo "$url_hash"
}

create_manifest() {
  local extract_dir="$1"
  python3 -c "
import json, glob, os
files = sorted(glob.glob('${extract_dir}/*.json'))
manifest = []
for f in files:
    with open(f) as fh:
        d = json.load(fh)
        d['hash'] = os.path.basename(f).replace('.json','')
        manifest.append(d)
with open('${extract_dir}/manifest.json', 'w') as fh:
    json.dump(manifest, fh, ensure_ascii=False, indent=2)
print(f'Manifest: {len(manifest)} entries')
"
}

create_plans_fixture() {
  local extract_dir="$1"
  local plan_file="$2"
  shift 2
  # Remaining args: hash1,title1,hash2,title2,...
  python3 -c "
import json, sys
plans = []
args = sys.argv[1:]
for i in range(0, len(args), 2):
    plans.append({
        'hash': args[i],
        'title': args[i+1],
        'language': 'en',
        'template': 'standard',
        'tags': ['test', 'example'],
        'concept_updates': [],
        'concept_new': [],
        'moc_targets': []
    })
with open('${plan_file}', 'w') as f:
    json.dump(plans, f, ensure_ascii=False, indent=2)
" "$@"
}

# ── Section Header ──────────────────────────────────────────────────────────

section() {
  echo ""
  echo "━━━ $1 ━━━"
}

# ── Summary ─────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Results: $_TESTS_PASSED passed / $_TESTS_FAILED failed / $_TESTS_RUN total"
  if [ $_TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}FAILURES:${NC}"
    echo -e "$_FAILURES"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Return exit code based on failures
test_exit_code() {
  [ $_TESTS_FAILED -eq 0 ]
}
