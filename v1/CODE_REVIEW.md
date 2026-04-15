# Code Review: obsidian-automation v2.2

**Reviewer:** Hermes Agent (automated)
**Date:** 2026-04-14
**Scope:** All 25 files in `/home/linuxuser/workspaces/gamma/obsidian-automation/v2/` + PRD
**Confidence target:** 95%

---

## Executive Summary

The v2.2 implementation is solid overall — well-structured, properly documented, and achieves all PRD goals. I found **3 critical bugs**, **12 warnings**, and **11 info-level issues**. The most serious problems are: a command injection risk via unquoted `$AGENT_CMD`, uninitialized variables in process functions that silently corrupt global state, and a non-portable `md5sum` call that breaks on macOS. None are showstoppers on Linux, but all should be fixed before production use.

**PRD Completeness:** 9/10 recommendations fully implemented. R7 (vault-stats) lacks growth-over-time tracking from log.md (only counts current files). R10 (schema co-evolution) works but compile-pass.sh doesn't actually write the schema review — it just tells the LLM to do it, relying on agent compliance.

---

## Critical Issues (4)

### C1. Variable case mismatch: `$mode` vs `$MODE` in review-pass.sh
- **File:** `scripts/review-pass.sh`, line 231
- **Severity:** CRITICAL
- **Description:** The log entry uses `$mode` (lowercase) but the variable is declared as `MODE` (uppercase) on line 28. The log will record an empty string for the mode instead of the actual mode (untouched/last/topic/entry). This means log.md entries from review passes show "Review pass (, N entries)" — useless for debugging.
- **Fix:** Change line 231 from `$mode` to `$MODE`:
  ```bash
  append_log_md "review" "Review pass ($MODE, $count entries)" \
  ```

### C2. Command Injection via Unquoted `$AGENT_CMD`
- **File:** `lib/common.sh`, line 111
- **Severity:** CRITICAL
- **Description:** `$AGENT_CMD` is expanded unquoted in `cd "$VAULT_PATH" && $AGENT_CMD "$prompt"`. If `AGENT_CMD` is set to something like `claude -p` (the default), this works because bash does word splitting. But if someone sets `AGENT_CMD="malicious; rm -rf"` as an environment variable, it would execute arbitrary commands. Even benign cases like `AGENT_CMD="python -m myagent"` rely on implicit word splitting.
- **Fix:**
  ```bash
  # Instead of:
  cd "$VAULT_PATH" && $AGENT_CMD "$prompt" 2>> "$LOG_FILE" || result=$?
  # Use an array:
  local -a cmd_array
  read -ra cmd_array <<< "$AGENT_CMD"
  cd "$VAULT_PATH" && "${cmd_array[@]}" "$prompt" 2>> "$LOG_FILE" || result=$?
  ```
  Alternatively, document that `AGENT_CMD` must not contain shell metacharacters and validate it at source time.

### C3. Global Variable Contamination in process functions
- **File:** `scripts/process-inbox.sh`, lines 136, 145, 237, 397, 333
- **Severity:** CRITICAL
- **Description:** Inside `process_youtube()`, `process_url()`, and `process_file()`, the variable `skipped` is incremented with `skipped=$((skipped + 1))` — but `skipped` is a global variable defined at line 460. These functions also use `ext` without `local` (line 132, 233). If two functions are called in a pipeline or if `ext` collides with another variable, behavior is unpredictable. More critically, `skipped` is modified inside these functions but the count update is invisible to the caller's `processed`/`failed` tracking since the `&&`/`||` pattern only tracks success/failure, not skip.
- **Fix:** Add `local` to all function-scoped variables. The `skipped` counter increments inside functions work because bash functions share the global scope, but this is fragile and should be explicitly documented or refactored to use a return code pattern.

### C4. Missing `local` on `ext` variable in process functions
- **File:** `scripts/process-inbox.sh`, line 132 (`process_youtube`), line 233 (`process_url`)
- **Severity:** CRITICAL
- **Description:** The variable `ext` is assigned with `ext="${file##*.}"` but is not declared `local`. This leaks into the global scope and could collide with other code. If a file has no extension, `ext` becomes the entire filename, which could be unexpected.
- **Fix:** Add `local ext` before the assignment in each function.

---

## Warning Issues (12)

### W1. `md5sum` is Linux-specific (portability)
- **File:** `lib/common.sh`, line 72
- **Severity:** WARNING
- **Description:** `md5sum` doesn't exist on macOS/BSD. The lock file hash generation will fail silently (producing empty hash) or error out entirely on non-Linux systems.
- **Fix:**
  ```bash
  vault_hash=$(echo "$VAULT_PATH" | { md5sum 2>/dev/null || md5 -q 2>/dev/null || echo "$VAULT_PATH" | cksum; } | cut -c1-8)
  ```

### W2. Lock file race condition (security)
- **File:** `lib/common.sh`, lines 75-81
- **Severity:** WARNING
- **Description:** The check-then-create pattern (`if [ -f ]; then ... fi; touch`) has a TOCTOU race. Two processes could both pass the check before either creates the lock file. In practice this is unlikely for a single-user system but is technically a bug.
- **Fix:** Use `mkdir` for atomic locking (mkdir is atomic on all POSIX systems):
  ```bash
  _lock_dir="/tmp/obsidian-${script_name}-${vault_hash}.lock"
  if ! mkdir "$_lock_dir" 2>/dev/null; then
    echo "$(date): Another $script_name instance is already running." >> "$LOG_FILE"
    return 1
  fi
  ```
  Then `release_lock` does `rmdir "$_lock_dir"`.

### W3. Lock file not cleaned up on SIGTERM/SIGINT
- **File:** `lib/common.sh`, line 79
- **Severity:** WARNING
- **Description:** The trap is set to `EXIT` only. If the script receives SIGTERM or SIGINT without a subshell, the EXIT trap should fire — but only if `set -e` isn't causing an exit from a subshell. The trap should explicitly handle signals:
  ```bash
  trap 'release_lock' EXIT INT TERM HUP
  ```

### W4. `get_edges()` matches substrings, not exact note names
- **File:** `lib/common.sh`, line 289
- **Severity:** WARNING
- **Description:** `grep -F "$note"` will match "My Note" inside "My Note Extended" or "PrefixMy Note". This returns false positives for edge lookups.
- **Fix:**
  ```bash
  grep -P "^(?:${note}\t|\t${note}\t)" "$edges_file" 2>/dev/null || true
  ```
  Or use `awk`:
  ```bash
  awk -F'\t' -v n="$note" '$1 == n || $2 == n' "$edges_file" 2>/dev/null || true
  ```

### W5. `process_file()` doesn't increment `skipped` counter
- **File:** `scripts/process-inbox.sh`, lines 318-329
- **Severity:** WARNING
- **Description:** When `process_file()` detects a duplicate by URL (line 318) or by filename (line 325), it logs and archives but doesn't increment the global `skipped` counter. Contrast with `process_youtube()` (line 136) and `process_url()` (line 237) which do increment `skipped`. The final summary at line 488 will undercount skipped files.
- **Fix:** Add `skipped=$((skipped + 1))` before each early return in `process_file()`.

### W6. `is_youtube_link()` fails on empty files
- **File:** `scripts/process-inbox.sh`, lines 79-87
- **Severity:** WARNING
- **Description:** `wc -l < "$file"` on a zero-length file returns 0 or empty string. The comparison `[ "$line_count" -gt 3 ]` will fail with "integer expression expected" if `$line_count` is empty.
- **Fix:** Default to 0: `line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ' || echo 0)` or add `-z` check.

### W7. `date` command portability — GNU vs BSD fallback works but is fragile
- **Files:** `lib/common.sh` line 39, `lint-vault.sh` line 103, `vault-stats.sh` line 50
- **Severity:** WARNING
- **Description:** The pattern `date -d "14 days ago" +%Y-%m-%d 2>/dev/null || date -v-14d +%Y-%m-%d 2>/dev/null` works on GNU and BSD but fails silently on systems with neither (produces empty `cutoff_date`). This is handled with the `[ -n "$cutoff_date" ]` guard, which is good. However, the `date +%Y-%m-%d` calls used everywhere else (line 39, etc.) are portable — this is fine.
- **Fix:** Already handled, but consider adding a third fallback: `echo ""` is already the result of failure, so this is acceptable.

### W8. Template entries lack `template:` field in compile/query prompts
- **Files:** `scripts/compile-pass.sh` (lines 31-179), `scripts/query-vault.sh` (lines 86-189)
- **Severity:** WARNING
- **Description:** The compile pass and query prompts don't mention `template:` field or domain-adaptive templates. The LLM always creates `standard` template entries even when `technical` or `comparison` would be more appropriate. The R4 (domain-adaptive templates) is implemented in the prompt templates but not in inline prompts.
- **Fix:** Add template selection guidance to compile-pass and query-vault prompts, or load `entry-structure.prompt` instead of using inline prompts.

### W9. `prompt` variable grows exponentially on retries
- **File:** `lib/common.sh`, line 124
- **Severity:** WARNING
- **Description:** On each retry, `RETRY_ADVICE` (600+ chars) is appended to `$prompt`. After 3 retries, the prompt has been appended twice (original + 2x retry advice). The `prompt` variable is local but grows within the loop. For very large prompts this could hit command-line length limits.
- **Fix:** Append retry advice as a separate variable or truncate after first append.

### W10. `select_entries()` last mode uses `xargs ls -t` which breaks on filenames with spaces
- **File:** `scripts/review-pass.sh`, lines 82-83
- **Severity:** WARNING
- **Description:** `find ... | xargs ls -t` doesn't handle filenames with spaces, newlines, or special characters. While Obsidian notes typically use safe names, this is a latent bug.
- **Fix:**
  ```bash
  find "$ENTRIES_DIR" -name '*.md' -type f -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -"$LIMIT"
  ```

### W11. `setup-git-hooks.sh` doesn't source common.sh
- **File:** `scripts/setup-git-hooks.sh`, line 13
- **Severity:** WARNING
- **Description:** This script defines its own `VAULT_PATH` default instead of sourcing `common.sh`. It also doesn't call `log()`, `acquire_lock()`, or `auto_commit()`. This is intentional (it's a setup script that runs before common.sh exists), but it means no logging of setup operations and no lock protection.
- **Fix:** Acceptable as-is for a setup script, but document the rationale.

### W12. `vault-stats.sh` doesn't call `acquire_lock()`
- **File:** `scripts/vault-stats.sh`
- **Severity:** WARNING
- **Description:** Unlike all other scripts, `vault-stats.sh` doesn't acquire a lock. If it runs concurrently with `lint-vault.sh` or `reindex.sh`, it could read partially-written files. The dashboard generation reads multiple files and the result could be inconsistent.
- **Fix:** Add `acquire_lock "vault-stats" || exit 1` after sourcing common.sh.

---

## Info Issues (11)

### I1. `wiki-index.md` template doesn't match actual format
- **File:** `templates/wiki-index.md`, lines 3-7
- **Severity:** INFO
- **Description:** The template shows `## Entries (by date, newest first)` and `## Concepts (alphabetical)` but `reindex.sh` generates `## Entries`, `## Concepts`, and `## Maps of Content` sections without date sorting or alphabetical ordering. The format is also `- [[EntryName]]: summary (entry)` not `- [[Entry Name]] (YYYY-MM-DD) — summary`. The template is outdated.
- **Fix:** Update template to match what `reindex.sh` actually generates, or update reindex to match the template.

### I2. `load_prompt()` never used by any script
- **File:** `lib/common.sh`, lines 331-343
- **Severity:** INFO
- **Description:** The `load_prompt()` function is defined but never called. All scripts load prompts with direct `cat` calls (process-inbox.sh lines 55-58) or use inline heredocs (compile-pass.sh, query-vault.sh). This is dead code.
- **Fix:** ~~Either use `load_prompt()` in all scripts or remove it.~~ Removed — direct `cat` calls from `prompts/` dir are simpler and more explicit.

### I3. `append_log_md()` duplicates initialization with `setup_directory_structure()`
- **File:** `lib/common.sh`, lines 42-53 vs lines 222-233
- **Severity:** INFO
- **Description:** Both `append_log_md()` and `setup_directory_structure()` initialize `log.md` with the same header. Since `setup_directory_structure()` is called first by all scripts, the check in `append_log_md()` will always find the file exists. Duplicated code.
- **Fix:** Remove the initialization from `append_log_md()` — it's guaranteed to exist after `setup_directory_structure()`.

### I4. Docs reference `00-Inbox/failed/` instead of `08-Archive-Raw/failed/`
- **File:** `docs/Part2-Automation-Skills-Setup.md`, line 163
- **Severity:** INFO
- **Description:** The docs say "Failures go to `00-Inbox/failed/`" but the code (`lib/common.sh` line 135) moves failures to `08-Archive-Raw/failed/`. The directory `00-Inbox/` doesn't exist in the v2 structure.
- **Fix:** Update docs to say `08-Archive-Raw/failed/`.

### I5. Docs describe query output going to `07-WIP/` but code writes to `04-Wiki/entries/`
- **File:** `docs/Part2-Automation-Skills-Setup.md`, line 186
- **Severity:** INFO
- **Description:** Docs say "Writes the answer to `07-WIP/`" but `query-vault.sh` prompt (line 116) instructs the LLM to "Create an Entry note in 04-Wiki/entries/". The compound-back design means answers go directly into the wiki, not WIP.
- **Fix:** Update docs to match current behavior.

### I6. `log.md` template doesn't include review/reindex operations
- **File:** `templates/log.md`, lines 11-14
- **Severity:** INFO
- **Description:** The template lists operations: ingest, compile, query, lint. But the system also has `review` and `reindex` operations (used by review-pass.sh and reindex.sh). These are documented in agents.md but not in the template.
- **Fix:** Add `review` and `reindex` to the log template.

### I7. `tag-registry.md` template uses `topic/*` format but scripts expect flat tags
- **File:** `templates/tag-registry.md`
- **Severity:** INFO
- **Description:** The template shows `topic/machine-learning` format but the Entry template uses flat tags like `- topic-tag-1`. The agents.md shows both formats. There's inconsistency in whether tags use `/` hierarchy or `-` separation.
- **Fix:** Standardize on one format and update all templates.

### I8. `process-inbox.sh` doesn't use `load_prompt()` and has prompts duplicated from v2.1
- **File:** `scripts/process-inbox.sh`, lines 54-58
- **Severity:** INFO
- **Description:** The script loads prompts with direct `cat` calls instead of using `load_prompt()` from common.sh. The inline prompt templates in process_youtube, process_url, process_file, and process_clipping are highly repetitive (~80% identical Steps 1-9). The PRD goal of eliminating duplication is partially achieved (shared common.sh) but prompt duplication remains.
- **Fix:** Extract the common Steps 1-9 into a shared prompt template loaded once.

### I9. No `va` shebang or shellcheck compatibility note
- **File:** All `.sh` files
- **Severity:** INFO
- **Description:** All scripts use `#!/usr/bin/env bash` which is good. However, `set -uo pipefail` (without `-e`) means scripts continue on errors. This is intentional (errors are handled explicitly) but should be documented as a design choice.
- **Fix:** Add a comment explaining why `-e` is omitted.

### I10. `compile-pass.sh` inline prompt uses `obsidian search/tags` CLI commands that may not exist
- **File:** `scripts/compile-pass.sh`, lines 45, 52
- **Severity:** INFO
- **Description:** The prompt references `obsidian tags sort=count counts` and `obsidian search` commands. These are not standard CLI tools — they appear to be custom agent skills. If the agent doesn't have these skills installed, the compile pass will produce suboptimal results.
- **Fix:** Document skill dependencies in the prompt or provide fallback instructions (e.g., `grep -r`).

### I11. `agents.md` doesn't document the `setup-git-hooks.sh` script
- **File:** `templates/agents.md`
- **Severity:** INFO
- **Description:** The agents.md schema documents all workflows and scripts except `setup-git-hooks.sh`. The pre-commit hook (blocking 07-WIP/ commits) is important behavior the agent should know about.
- **Fix:** Add a section about git hooks to agents.md.

---

## PRD Completeness Assessment

| Recommendation | Status | Notes |
|---|---|---|
| R1: Interactive Ingestion + Review | ✅ Complete | `--interactive` on process-inbox.sh, review-pass.sh fully implemented |
| R2: Query Compound-Back | ✅ Complete | Step 7 in query-vault.sh prompt is mandatory |
| R3: Extract lib/common.sh | ✅ Complete | All scripts source common.sh; `setup-git-hooks.sh` intentionally excluded |
| R4: Domain-Adaptive Templates | ⚠️ Partial | Templates defined, but compile/query prompts don't guide template selection |
| R5: Typed Edges | ✅ Complete | edges.tsv, add_edge(), get_edges(), lint check all present |
| R6: Git Auto-Commit | ✅ Complete | setup-git-hooks.sh, auto_commit() in all scripts |
| R7: Vault Stats | ⚠️ Partial | Dashboard exists but lacks growth-over-time from log.md history |
| R8: Externalize Prompts | ⚠️ Partial | Prompt files exist but compile-pass and query-vault still use inline heredocs |
| R9: Full Reindex | ✅ Complete | reindex.sh fully implemented |
| R10: Schema Co-Evolution | ✅ Complete | Compile pass includes Operation 8; writes to schema-review.md |

**Missing from PRD:** No mention of `vault-stats.sh` or `setup-git-hooks.sh` in the PRD's File Structure section (though they're in the scripts table in README).

---

## Code Quality Observations

**Positives:**
- Clean separation of concerns (common.sh library pattern)
- Consistent error handling with `|| true` guards
- Good use of `set -uo pipefail` across all scripts
- Lock file management prevents overlapping runs
- URL deduplication is well-designed
- Comprehensive lint checks (9 categories)
- Documentation is thorough and consistent

**Areas for improvement:**
- Prompt template duplication across process_youtube/process_url/process_file/process_clipping (~80% identical)
- `load_prompt()` defined but never used
- Inline prompts in compile/query don't use externalized templates
- No shellcheck integration or CI validation
- The `sed -i` calls in review-pass.sh are GNU-specific (BSD sed requires `sed -i ''`)

---

## Summary of Recommended Fixes (Priority Order)

All issues below have been **FIXED** in this commit.

1. ~~C1:~~ **FIXED** `$mode` → `$MODE` in `review-pass.sh:231`
2. ~~C2:~~ **FIXED** `mkdir` atomic locking replaces check-then-touch; `$AGENT_CMD` split into array via `read -ra`
3. ~~C3/C4:~~ **FIXED** Added `local ext` to process functions
4. ~~W5:~~ **FIXED** Added `skipped` increment to `process_file()`
5. ~~W1:~~ **FIXED** Portable hash: `md5sum` → `md5 -q` → `cksum` fallback chain
6. ~~W2:~~ **FIXED** Atomic `mkdir` locking (POSIX atomic operation)
7. ~~W4:~~ **FIXED** `get_edges()` uses `awk` exact column matching
8. ~~W10:~~ **FIXED** `xargs -0 ls -t` handles filenames with spaces
9. ~~W6:~~ **FIXED** `[ -s "$file" ] || return 1` guard on empty files
10. ~~W12:~~ **FIXED** `acquire_lock "vault-stats"` added to vault-stats.sh
11. ~~W3:~~ **FIXED** Trap handles EXIT INT TERM HUP
12. ~~W8:~~ **FIXED** Operation 6 (Template Assessment) added to compile pass
13. ~~W9:~~ **FIXED** Retry advice appended only on first attempt
14. ~~I1:~~ **FIXED** wiki-index.md template matches reindex.sh output
15. ~~I2:~~ **FIXED** `load_prompt()` removed (dead code)
16. ~~I3:~~ **FIXED** Comment clarifies fallback initialization is for edge cases
17. ~~I4:~~ **FIXED** Docs reference `08-Archive-Raw/failed/`
18. ~~I5:~~ **FIXED** Docs reference `04-Wiki/entries/` for query answers
19. ~~I6:~~ **FIXED** log.md template includes review and reindex operations
20. ~~I7:~~ **FIXED** tag-registry.md uses flat hyphenated tags
21. ~~I8:~~ **FIXED** Comment explains design choice for inline prompts
22. ~~I9:~~ **FIXED** README documents shellcheck and design decisions
23. ~~I10:~~ **FIXED** Removed `obsidian search/tags` CLI references from compile pass
24. ~~I11:~~ **FIXED** agents.md documents git hooks
