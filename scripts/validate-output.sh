#!/usr/bin/env bash
# ============================================================================
# v2.1.0: validate-output.sh — Post-write quality gate
# ============================================================================
# Validates files written by pipeline agents. Checks YAML frontmatter,
# required sections, stubs, tag format, wikilink quoting.
#
# Usage: ./validate-output.sh [--vault PATH] [--since TIMESTAMP] [--fix]
#
# Exit codes: 0 = all valid, 1 = violations found, 2 = fatal error
# Output: JSON report to stdout, human-readable to stderr
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

VAULT="${VAULT_PATH:-$HOME/MyVault}"
SINCE=""
FIX_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault)  VAULT="$2"; shift 2 ;;
    --since)  SINCE="$2"; shift 2 ;;
    --fix)    FIX_MODE=true; shift ;;
    *)        echo "Unknown arg: $1"; exit 2 ;;
  esac
done

# ═══════════════════════════════════════════════════════════
# VALIDATION FUNCTIONS
# ═══════════════════════════════════════════════════════════

violations=0
warnings=0
files_checked=0

report_violation() {
  local file="$1"
  local check="$2"
  local detail="$3"
  violations=$((violations + 1))
  echo "VIOLATION|$file|$check|$detail"
}

report_warning() {
  local file="$1"
  local check="$2"
  local detail="$3"
  warnings=$((warnings + 1))
  echo "WARNING|$file|$check|$detail"
}

# Check 1: YAML frontmatter parses correctly
check_frontmatter() {
  local file="$1"
  # Extract YAML between first two --- lines
  local yaml
  yaml=$(python3 -c "
import sys
with open(sys.argv[1]) as f:
    content = f.read()
if content.startswith('---'):
    end = content.find('---', 3)
    if end > 0:
        print(content[3:end])
        sys.exit(0)
print('')
" "$file" 2>/dev/null)

  if [ -z "$yaml" ]; then
    report_violation "$file" "frontmatter" "No YAML frontmatter found"
    return
  fi

  # Validate YAML parses
  if ! echo "$yaml" | python3 -c "import yaml, sys; yaml.safe_load(sys.stdin)" 2>/dev/null; then
    report_violation "$file" "frontmatter" "YAML frontmatter failed to parse"
    return
  fi

  # Check for null values in YAML (Obsidian doesn't render null well)
  if echo "$yaml" | grep -qE ':\s*null\s*$' 2>/dev/null; then
    report_violation "$file" "frontmatter" "YAML contains 'null' value — use empty string instead (reviewed: \"\")"
  fi

  # Check quoted wikilinks in YAML (source: "[[note]]")
  if echo "$yaml" | grep -qE 'source: \[\[' 2>/dev/null; then
    if ! echo "$yaml" | grep -qE 'source: "\[\[' 2>/dev/null; then
      report_violation "$file" "frontmatter" "Wikilink in YAML not quoted (should be source: \"[[note]]\")"
    fi
  fi
}

# Check 2: Required sections for each template type
check_sections() {
  local file="$1"
  local content
  content=$(cat "$file")

  # Detect template from frontmatter
  local template
  template=$(python3 -c "
import sys, yaml
with open(sys.argv[1]) as f:
    content = f.read()
if content.startswith('---'):
    end = content.find('---', 3)
    if end > 0:
        try:
            fm = yaml.safe_load(content[3:end])
            if isinstance(fm, dict):
                print(fm.get('template', 'standard'))
                sys.exit(0)
        except: pass
print('standard')
" "$file" 2>/dev/null || echo "standard")

  local note_type="unknown"
  # Detect note type from file path
  if [[ "$file" == */entries/* ]]; then
    note_type="entry"
  elif [[ "$file" == */concepts/* ]]; then
    note_type="concept"
  elif [[ "$file" == */mocs/* ]]; then
    note_type="moc"
  elif [[ "$file" == */sources/* ]]; then
    note_type="source"
    return  # Sources don't need section validation
  else
    return
  fi

  # Entry section checks
  if [ "$note_type" = "entry" ]; then
    case "$template" in
      standard|chinese)
        local required_sections=("Summary" "Core insights" "Other takeaways" "Open questions" "Linked concepts")
        if [ "$template" = "chinese" ]; then
          required_sections=("摘要" "核心发现" "其他要点" "开放问题" "关联概念")
        fi
        for section in "${required_sections[@]}"; do
          if ! echo "$content" | grep -q "^## $section" 2>/dev/null; then
            report_violation "$file" "sections" "Missing required section: ## $section"
          fi
        done
        ;;
      technical)
        for section in "Summary" "Key Findings" "Data/Evidence" "Limitations" "Linked concepts"; do
          if ! echo "$content" | grep -q "^## $section" 2>/dev/null; then
            report_violation "$file" "sections" "Missing required section: ## $section"
          fi
        done
        ;;
      procedural)
        for section in "Summary" "Steps" "Linked concepts"; do
          if ! echo "$content" | grep -q "^## $section" 2>/dev/null; then
            report_violation "$file" "sections" "Missing required section: ## $section"
          fi
        done
        ;;
    esac
  fi

  # Concept section checks
  if [ "$note_type" = "concept" ]; then
    local lang
    lang=$(python3 -c "
import sys, yaml
with open(sys.argv[1]) as f:
    content = f.read()
if content.startswith('---'):
    end = content.find('---', 3)
    if end > 0:
        try:
            fm = yaml.safe_load(content[3:end])
            if isinstance(fm, dict):
                print(fm.get('language', 'en'))
                sys.exit(0)
        except: pass
print('en')
" "$file" 2>/dev/null || echo "en")

    if [ "$lang" = "zh" ]; then
      for section in "核心概念" "背景" "关联"; do
        if ! echo "$content" | grep -q "^## $section" 2>/dev/null; then
          report_violation "$file" "sections" "Missing required section: ## $section"
        fi
      done
    else
      for section in "Core concept" "Context" "Links"; do
        if ! echo "$content" | grep -q "^## $section" 2>/dev/null; then
          report_violation "$file" "sections" "Missing required section: ## $section"
        fi
      done
    fi
  fi
}

# Check 3: Stubs
check_stubs() {
  local file="$1"
  local content
  content=$(cat "$file")

  local stub_patterns=("TODO" "FIXME" "PLACEHOLDER" "TBD" "待补充" "待填" "[insert" "Content goes here" "Write your" "Lorem ipsum")

  for pattern in "${stub_patterns[@]}"; do
    if echo "$content" | grep -qi "$pattern" 2>/dev/null; then
      report_violation "$file" "stubs" "Stub text found: '$pattern'"
    fi
  done
}

# Check 4: Tag format
check_tags() {
  local file="$1"
  local content
  content=$(cat "$file")

  # Check for banned tags
  local banned_tags=("x.com" "tweet" "source" "http" "url" "link")
  for tag in "${banned_tags[@]}"; do
    if echo "$content" | grep -q "^  - $tag$" 2>/dev/null; then
      report_violation "$file" "tags" "Banned tag: '$tag' (use topic-specific tags)"
    fi
  done
}

# Check 5: No overwrites of existing files (check git status for unexpected modifications)
check_no_overwrites() {
  local file="$1"
  # If the file existed before the pipeline run and was modified (not created),
  # that could be an overwrite. We check by seeing if git tracks it as modified.
  if command -v git &>/dev/null && [ -d "$VAULT/.git" ]; then
    cd "$VAULT"
    if git diff --name-only 2>/dev/null | grep -qF "$(basename "$file")"; then
      report_warning "$file" "overwrite" "File was modified (possible overwrite of existing content)"
    fi
  fi
}

# Check 6: Markdown formatting (H1 title, blank lines after headings)
check_markdown_format() {
  local file="$1"
  local content
  content=$(cat "$file")

  # Extract body (after frontmatter)
  local body
  body=$(python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
m = re.match(r'^---\n.*?\n---\n(.*)', content, re.DOTALL)
if m:
    sys.stdout.write(m.group(1))
else:
    sys.stdout.write(content)
" "$file" 2>/dev/null)

  if [ -z "$body" ]; then return; fi

  # Check 1: First non-empty line should be H1 title
  local first_line
  first_line=$(echo "$body" | grep -m1 -v '^\s*$' 2>/dev/null)
  if [ -n "$first_line" ] && [[ ! "$first_line" =~ ^#\  ]]; then
    report_violation "$file" "format" "Body must start with H1 title (# Title), found: ${first_line:0:60}"
  fi

  # Check 2: Blank line after ## headings
  local line_num=0
  local prev_was_heading=false
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [[ "$line" =~ ^## ]]; then
      prev_was_heading=true
    elif [ "$prev_was_heading" = true ]; then
      if [ -n "$line" ]; then
        report_violation "$file" "format" "Missing blank line after heading at line $((line_num - 1)): next line has content"
      fi
      prev_was_heading=false
    else
      prev_was_heading=false
    fi
  done <<< "$body"
}

# ═══════════════════════════════════════════════════════════
# FIX FUNCTIONS (--fix mode)
# ═══════════════════════════════════════════════════════════

fixes_applied=0

report_fix() {
  local file="$1"
  local fix="$2"
  fixes_applied=$((fixes_applied + 1))
  echo "FIX|$file|$fix"
}

# Fix 1: YAML frontmatter — null values + unquoted wikilinks
fix_frontmatter() {
  local file="$1"
  local changed=false

  python3 -c "
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

original = content

# Fix null values: 'key: null' → 'key: \"\"'
content = re.sub(r'(:\s*)null(\s*$)', r'\1\"\"\2', content, flags=re.MULTILINE)

# Fix unquoted wikilinks in YAML: source: [[note]] → source: \"[[note]]\"
# Only within frontmatter
fm_match = re.match(r'^(---\n)(.*?)(---\n)', content, re.DOTALL)
if fm_match:
    fm = fm_match.group(2)
    fixed_fm = re.sub(r'(\[\[[^\]]+\]\])', r'\"\\1\"', fm)
    # Avoid double-quoting: if already quoted, skip
    fixed_fm = re.sub(r'\"\"(\[\[[^\]]+\]\])\"\"', r'\"\\1\"', fixed_fm)
    content = fm_match.group(1) + fixed_fm + fm_match.group(3) + content[fm_match.end():]

if content != original:
    with open(sys.argv[1], 'w') as f:
        f.write(content)
    print('changed')
" "$file" 2>/dev/null | grep -q 'changed' && changed=true

  if $changed; then
    report_fix "$file" "frontmatter: fixed null values or unquoted wikilinks"
  fi
}

# Fix 2: Markdown format — blank lines after headings + H1 title
fix_markdown_format() {
  local file="$1"
  local changed=false

  python3 -c "
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

original = content

# Split into frontmatter and body
fm_match = re.match(r'^(---\n.*?\n---\n)(.*)', content, re.DOTALL)
if fm_match:
    frontmatter = fm_match.group(1)
    body = fm_match.group(2)
else:
    frontmatter = ''
    body = content

# Fix 1: Ensure body starts with H1 title
first_nonempty = ''
for line in body.split('\n'):
    if line.strip():
        first_nonempty = line
        break

if first_nonempty and not first_nonempty.startswith('# '):
    # Extract title from frontmatter
    title_match = re.search(r'^title:\s*[\"'\'']?(.*?)[\"'\'']?\s*$', frontmatter, re.MULTILINE)
    title = title_match.group(1) if title_match else 'Untitled'
    body = f'# {title}\n\n{body}'

# Fix 2: Add blank line after ## headings if missing
lines = body.split('\n')
fixed_lines = []
i = 0
while i < len(lines):
    fixed_lines.append(lines[i])
    if lines[i].startswith('## ') or lines[i].startswith('### '):
        # Check if next line exists and is non-empty
        if i + 1 < len(lines) and lines[i + 1].strip() != '' and not lines[i + 1].startswith('#'):
            fixed_lines.append('')  # Insert blank line
    i += 1
body = '\n'.join(fixed_lines)

# Fix 3: Ensure blank line before ## headings (if previous line is non-empty)
lines = body.split('\n')
fixed_lines = []
for i, line in enumerate(lines):
    if (line.startswith('## ') or line.startswith('### ')) and i > 0:
        if fixed_lines and fixed_lines[-1].strip() != '':
            fixed_lines.append('')
    fixed_lines.append(line)
body = '\n'.join(fixed_lines)

# Normalize multiple blank lines to max 2
body = re.sub(r'\n{3,}', '\n\n', body)

content = frontmatter + body
if content != original:
    with open(sys.argv[1], 'w') as f:
        f.write(content)
    print('changed')
" "$file" 2>/dev/null | grep -q 'changed' && changed=true

  if $changed; then
    report_fix "$file" "format: fixed blank lines and/or added H1 title"
  fi
}

# Fix 3: Remove banned tags
fix_banned_tags() {
  local file="$1"
  local changed=false
  local content
  content=$(cat "$file")

  local banned_tags=("x.com" "tweet" "source" "http" "url" "link")
  for tag in "${banned_tags[@]}"; do
    if echo "$content" | grep -qE "^  - ${tag}$" 2>/dev/null; then
      # Remove the banned tag line
      local new_content
      new_content=$(echo "$content" | sed "/^  - ${tag}$/d")
      echo "$new_content" > "$file"
      content="$new_content"
      changed=true
      report_fix "$file" "tags: removed banned tag '$tag'"
    fi
  done
}

# ═══════════════════════════════════════════════════════════
# MAIN VALIDATION LOOP
# ═══════════════════════════════════════════════════════════

# Find files to validate
find_args=("$VAULT/04-Wiki" -name "*.md" -type f)
if [ -n "$SINCE" ]; then
  find_args+=(-newer "$SINCE")
fi

while IFS= read -r file; do
  [ -f "$file" ] || continue
  files_checked=$((files_checked + 1))

  # In fix mode, apply fixes first, then validate
  if $FIX_MODE; then
    fix_frontmatter "$file"
    fix_markdown_format "$file"
    fix_banned_tags "$file"
  fi

  check_frontmatter "$file"
  check_sections "$file"
  check_stubs "$file"
  check_tags "$file"
  check_no_overwrites "$file"
  check_markdown_format "$file"

done < <(find "${find_args[@]}" 2>/dev/null | sort)

# ═══════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════

echo "" >&2
echo "━━━ Validation Report ━━━" >&2
echo "Files checked: $files_checked" >&2
if $FIX_MODE; then
  echo "Fixes applied: $fixes_applied" >&2
fi
echo "Violations:    $violations" >&2
echo "Warnings:      $warnings" >&2

if [ "$violations" -gt 0 ]; then
  echo "" >&2
  echo "Status: FAILED — $violations violation(s) found" >&2
  if $FIX_MODE; then
    echo "Some issues were auto-fixed ($fixes_applied fixes), but $violations remain." >&2
  fi
  echo "" >&2
  echo "Run with --fix to auto-repair safe issues (frontmatter, format, banned tags)." >&2
  exit 1
else
  echo "" >&2
  echo "Status: PASSED" >&2
  exit 0
fi
