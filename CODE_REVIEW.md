# Code Review: obsidian-automation v2.1.0

**Reviewers:** Codex Agent + Claude Agent + Hermes Agent (parallel)
**Date:** 2026-04-18
**Method:** Full end-to-end, all 40+ files, line-by-line across 3 independent reviewers
**Overall Health:** 7/10 — sound architecture, real bugs in implementation

---

## CRITICAL (Fix Immediately)

### C1. Truncated API key variable names — BREAKS transcript extraction
**Files:** `scripts/stage1-extract.sh:57`, `scripts/extract-transcript.sh:80,110`, `lib/transcribe.sh:31`

Three files use truncated variable names instead of full env var names:
- `$TRANS...KEY` instead of `$TRANSCRIPT_API_KEY` (stage1:57, extract-transcript:80)
- `$SUPAD...KEY` instead of `$SUPADATA_API_KEY` (extract-transcript:110)
- `${ASSE...Y:-}` instead of `${ASSEMBLYAI_API_KEY:-}` (transcribe.sh:31)

**Impact:** YouTube transcript extraction via TranscriptAPI fails silently every time. AssemblyAI transcription for podcasts always fails. Supadata fallback never triggers.

**Fix:** Replace all truncated names with full variable names.

### C2. Wrong heresdoc invocation in `run_with_retry()` — garbles agent prompts
**File:** `lib/common.sh:172`

```bash
cd "$VAULT_PATH" && timeout 600 bash -c '"$AGENT_CMD" chat' <<< "$prompt" 2>> "$LOG_FILE" || result=$?
```

Uses `<<<` heredoc instead of required `-q "$prompt" -Q` flags. Shell metacharacters in prompts ($, backticks) get corrupted by bash expansion. Missing `-Q` flag means verbose agent output pollutes parseable output.

**Impact:** Every script using `run_with_retry()` (compile-pass, query-vault, review-pass) may produce corrupted agent responses.

**Fix:** Change to `timeout 600 "$AGENT_CMD" chat -q "$prompt" -Q 2>>"$LOG_FILE" || result=$?`

### C3. `set -uo pipefail` — missing `-e` flag
**File:** `lib/common.sh:20`

Scripts sourced from common.sh inherit `set -uo pipefail` without `-e`. Command failures are silently ignored throughout the entire pipeline. Any `sed`, `jq`, or `curl` failure continues with corrupt output.

**Impact:** Silent data corruption. A failed sed substitution means a malformed prompt is passed to the agent, which may succeed with garbage output.

**Fix:** Change to `set -euo pipefail`

### C4. `skills/obsidian-ingest.md` version says `3.0.0` — contradicts everything
**File:** `skills/obsidian-ingest.md:4`

Every other file says v2.1.0 (README, PRD, templates/agents.md, common.sh, extract.sh). Skill file alone claims 3.0.0 with no explanation.

**Impact:** Version confusion. Anyone checking skill version against codebase sees a mismatch.

**Fix:** Change to `version: 2.1.0`

---

## HIGH (Fix This Week)

### H1. Lock cleanup uses `rmdir` — always fails, stale locks accumulate
**File:** `lib/common.sh:144`

```bash
release_lock() {
  rmdir "$_lock_dir" 2>/dev/null || true
}
```

`acquire_lock()` writes a `pid` file inside the lock dir (line 139). `rmdir` can only remove empty directories. Result: lock dirs with PID files never get cleaned, stale locks accumulate in `/tmp`.

**Fix:** Change to `rm -rf "$_lock_dir" 2>/dev/null || true`

### H2. Race condition in parallel extraction — duplicate URLs corrupt output
**File:** `scripts/stage1-extract.sh:507-516`

Parallel xargs with `-P 4` writes to `"$EXTRACT_DIR/${url_hash}.json"`. If two different inbox files contain the same URL, both processes write to the same hash file simultaneously — file corruption.

**Fix:** Use `mkdir`-based locking per hash or `flock`.

### H3. PyYAML dependency unchecked — validation silently passes on invalid YAML
**File:** `scripts/validate-output.sh:79`

If PyYAML isn't installed, the Python YAML check fails silently (due to `2>/dev/null`), meaning invalid frontmatter is never caught.

**Fix:** Add preflight: `python3 -c "import yaml" 2>/dev/null || echo "WARNING: PyYAML not installed"`

### H4. `qmd_wrapper.py` temp file leak on exception
**File:** `lib/qmd_wrapper.py:59-84`

If `json.dump()` raises an exception, the temp file leaks. Bare `except:` at line 82 swallows all exceptions silently.

**Fix:** Use `try/finally` with `os.unlink()` cleanup.

### H5. edges.tsv parser reads 3 columns — format has 4
**File:** `scripts/lint-vault.sh:447`

```bash
while IFS=$'\t' read -r source relation target; do
```

But `edges.tsv` format is `source<tab>target<tab>type<tab>description` (4 columns, per common.sh:318). Parser reads `target` into `relation` variable, causing false positive warnings.

**Fix:** `while IFS=$'\t' read -r source target edge_type description; do`

### H6. `templates/Source.md` uses `source/type` — contradicts tag-registry.md
**File:** `templates/Source.md:9`

Tag `source/type` uses hierarchical format, but `tag-registry.md` explicitly says "Do not use hierarchical `topic/` format."

**Fix:** Change `- source/type` to `- source`

### H7. v1/CODE_REVIEW.md references non-existent `v2/` directory
**File:** `v1/CODE_REVIEW.md:1,5`

Claims "v2.2" (wrong version) and scopes to "25 files in `v2/`" which doesn't exist. Pre-reorganization artifact, now actively misleading.

**Fix:** Add `⚠️ STALE — pre-reorganization artifact` header or delete.

---

## MEDIUM (Fix This Sprint)

### M1. `/tmp/extracted/` shared across all invocations — no isolation
**Files:** `process-inbox.sh:110`, `stage1-extract.sh:35`, `stage2-plan.sh:23`, `stage3-create.sh:21`

Global fixed path with no per-vault or per-invocation isolation. Lock prevents same-vault concurrency but not different-vault data stomping.

**Fix:** Use `/tmp/obsidian-extracted-${vault_hash}/`

### M2. `--resume` depends on `/tmp/extracted/` surviving across runs
**File:** `scripts/process-inbox.sh:139-142`

If user reboots between `--review` and `--resume`, the manifest is lost. No persistence mechanism.

**Fix:** Copy manifest.json to vault's `07-WIP/` during `--review` mode.

### M3. All agent invocations inconsistent — `-q`/`-Q` flags vs heredoc
**Files:** `stage2-plan.sh:252`, `stage3-create.sh:186` use `-q`. `common.sh:172` uses heredoc. No documented standard.

**Fix:** Standardize on `-q "$prompt" -Q` everywhere. Add preflight check for AGENT_CMD validity.

### M4. `qmd_batch_concept_search()` re-inits daemon session per batch
**File:** `lib/common.sh:707-735`

Comment says "one daemon init, N queries" but code calls `_curl_init()` per batch invocation — N sessions instead of 1.

**Fix:** Pass session_id as env var or maintain persistent session.

### M5. Batch prompt size not capped — defeats "5K prompt" claim
**File:** `scripts/build_batch_prompt.py:65`

Each source truncated to 8000 chars, but N sources concatenated. 6 sources = 48K+ chars, far exceeding README's "5K prompt" claim.

**Fix:** Add total prompt size cap, reduce per-source truncation dynamically.

### M6. `validate-output.sh` flags `null` but test fixtures use `null`
**Files:** `validate-output.sh:85-87`, `test_end_to_end.sh:223`

Test fixtures write `reviewed: null` but validator flags `: null` as violation. Tests would fail their own validation.

**Fix:** Change test fixtures to `reviewed: ""`

### M7. `.env.example` model name doesn't match actual default
**File:** `.env.example:29`

Shows `all-MiniLM-L6-v2` but `common.sh:575` defaults to `Qwen3-Embedding-0.6B-Q8_0.gguf`.

**Fix:** Update `.env.example` to match actual default.

### M8. v1/docs/ reference wrong v2 directories
**Files:** `v1/docs/Part2-Automation-Skills-Setup.md:163,472`

Says "Failures go to `00-Inbox/failed/`" (v1 path) but v2 uses `08-Archive-Raw/failed/`. Says query answers go to `05-WIP/` but v2 uses `04-Wiki/entries/`.

**Fix:** Add `⚠️ v1-only` labels to all v1/docs/ files.

### M9. Missing preflight dependency checks
**File:** `lib/common.sh`

`hermes`, `python3`, `jq` used throughout but never checked at startup. `qmd` and `yt-dlp` are checked inline, others aren't.

**Fix:** Add `check_dependencies()` function called during preflight.

---

## LOW (Backlog)

| # | File | Issue |
|---|------|-------|
| L1 | `v1/README-v1.md:11,165-179` | Claims "v1 (current root)" — backwards. Repository structure section is inverted. |
| L2 | `reindex.sh:3` | Says "v2.0.1" — minor version drift from v2.1.0 |
| L3 | `v1/README-v1.md:19` | Says "8 checks" for v2.1 but actual system has 12 |
| L4 | `skills/obsidian-ingest.md:19-20` | Hardcoded paths `/home/linuxuser/...` — should use `$HOME` |
| L5 | `lint-vault.sh:503` | Stub patterns use `>` prefix — only catches blockquote stubs, not plain text |
| L6 | `v1/skills/obsidian-vault-auto.md:29` | Hardcoded `VAULT=~/cvjji9` — wrong path format |
| L7 | `test_integration.sh:27-28` | Writes to real `/tmp/extracted/` — race with actual pipeline |
| L8 | `grep -oP` in `extract.sh:43`, `stage1-extract.sh:112` | GNU-only, no BSD fallback |
| L9 | `test_edge_cases.sh:80` | Malformed regex — `\\\\\\\\.com` instead of `\\.com` |
| L10 | `v1/skills/*.md` (6 files) | No deprecation headers on any v1 skill files |

---

## TEST QUALITY ASSESSMENT

- **test_integration.sh**: Real integration test — creates mock vault, mock hermes, runs actual Stages 2+3. Better than initially claimed. **Valid for CI.**
- **test_end_to_end.sh**: Overlaps ~60% with test_integration.sh. Should consolidate.
- **test_qmd_integration.sh**: Requires live qmd binary — can't run in CI without it. Add skip logic.
- **test_stage1_extract.sh**: Only tests URL regex and hash generation — never calls actual extraction functions. **Needs real extraction tests.**

---

## VERSION CONSISTENCY MAP

| Location | Version | Status |
|----------|---------|--------|
| README.md | v2.1.0 | ✅ |
| PRD.md | v2.1.0 | ✅ |
| templates/agents.md | v2.1.0 | ✅ |
| lib/common.sh | v2.1.0 | ✅ |
| lib/extract.sh | v2.1.0 | ✅ |
| **skills/obsidian-ingest.md** | **3.0.0** | **❌ MISMATCH** |
| v1/CODE_REVIEW.md | v2.2 | ❌ STALE |
| reindex.sh | v2.0.1 | ⚠️ Minor drift |

---

## RECOMMENDED FIX PRIORITY

1. **C1-C3**: API keys, heresdoc, `-e` flag — pipeline is broken without these
2. **C4 + H7**: Version confusion — immediate cleanup
3. **H1-H6**: Lock cleanup, race conditions, validation — data integrity
4. **M1-M9**: Architecture gaps — reliability
5. **Test consolidation**: Merge test_end_to_end into test_integration, add extraction tests
6. **v1/ cleanup**: Deprecation headers or deletion of stale v1 files

---

*Previous review: v1/CODE_REVIEW.md (2026-04-14) — stale, references non-existent v2/ directory*
*This review supersedes all prior reviews.*
