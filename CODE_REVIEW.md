# Code Review: obsidian-automation v0.1.0

**Reviewers:** Agent1 (Codex — Bugs & Correctness) + Agent2 (Claude — Code Quality) + Agent3 (Codex — Architecture & Integration)
**Date:** 2026-04-19
**Method:** Full end-to-end, 76 files, line-by-line across 3 independent reviewers
**Tests:** 391 passed, 0 failed (post-fix)
**Overall Health:** 8.5/10

---

## CRITICAL (Fixed)

### C1. `review.py:149` — `archive_inbox()` missing required argument
**File:** `pipeline/review.py:149`
**Description:** `archive_inbox(cfg)` called with 1 arg, but signature is `archive_inbox(cfg, hashes: set[str])`. Crashes with `TypeError` at runtime.
**Fix:** Changed to `archive_inbox(cfg, set())`. The review workflow doesn't track individual hashes — passing empty set preserves existing behavior.
**Confirmed by:** All 3 agents

---

## HIGH (Fixed)

### H1. `extract.py:194` — Double-escaped newlines in failure content
**File:** `pipeline/extract.py:194`
**Description:** `content=f"URL: {url}\\n\\nNote: ..."` used `\\n\\n` (literal backslash-n) instead of `\n\n` (actual newlines). Vault notes from failed extractions would show `\n\n` as text.
**Fix:** Changed to `f"URL: {url}\n\nNote: ..."`
**Confirmed by:** Agent1 + Agent3

### H2. `web.py:70` — Same double-escaped newlines
**File:** `pipeline/extractors/web.py:70`
**Description:** Identical to H1 — web extraction failure fallback had literal `\n\n`.
**Fix:** Changed to `f"URL: {url}\n\nNote: ..."`
**Confirmed by:** Agent1 + Agent3

### H3. `extract.py:230-255` — ContentStore resource leak on exception
**File:** `pipeline/extract.py:230-255`
**Description:** `store.close()` was outside `try/finally`. If `ThreadPoolExecutor` raised, SQLite connection leaked.
**Fix:** Wrapped parallel execution in `try/finally` with `store.close()` in the `finally` block.
**Confirmed by:** Agent1 + Agent2 + Agent3

### H4. `compile.py:91-93` — Prompt directory resolved from wrong location
**File:** `pipeline/compile.py:91-93`
**Description:** `run_compile()` resolved prompts as `repo_root / "prompts"` but rest of pipeline uses `cfg.prompts_dir` (vault-based). If repo and vault are in different locations, compile-pass.prompt wouldn't be found.
**Fix:** Changed to `cfg.prompts_dir` with fallback to `repo_root/prompts`.
**Confirmed by:** Agent2 + Agent3

### H5. `create.py:975` — Incorrect `created` stat calculation
**File:** `pipeline/create.py:975`
**Description:** `created = plan_count - failed_count` assumed every plan either succeeds or fails. Doesn't account for plans that are skipped/deduped.
**Fix:** Changed to `created = sum(1 for r in results if r["status"] == "ok")` — counts actual successes.
**Confirmed by:** Agent1 + Agent2

---

## MEDIUM (Fixed)

### M1. `web.py:213` — Archive.org year hardcoded to 2024
**File:** `pipeline/extractors/web.py:213`
**Description:** `https://web.archive.org/web/2024/{url}` always requested 2024 snapshots. Newer content wouldn't be found as time passed.
**Fix:** Changed to `datetime.now().year`.
**Confirmed by:** Agent2 + Agent3

### M2. `_shared.py:223` — Whisper transcription hardcoded to English
**File:** `pipeline/extractors/_shared.py:223`
**Description:** `model.transcribe(audio_file, language="en")` forced English. Chinese podcast/video content would be garbled.
**Fix:** Removed `language="en"` — whisper auto-detects language.
**Confirmed by:** Agent3

### M3. `plan.py:347` — O(n²) string concatenation in prompt builder
**File:** `pipeline/plan.py:347-366`
**Description:** `sources_block += f"""..."""` in a loop creates O(n²) string copies. For large batches, this wastes memory and CPU.
**Fix:** Changed to `sources_block_parts.append()` with `"".join()` at end.
**Confirmed by:** Agent2

### M4. `create.py:517` — Same O(n²) string concatenation
**File:** `pipeline/create.py:517-533`
**Description:** Same pattern as M3 in batch prompt builder.
**Fix:** Changed to list-append + join.
**Confirmed by:** Agent2

---

## LOW (Fixed)

### L1. `pyproject.toml` — Missing `pyyaml` dependency
**File:** `pyproject.toml`
**Description:** `lint.py` imports `yaml` (PyYAML) but dependency not declared. Lint checks would silently skip YAML validation if not installed.
**Fix:** Added `"pyyaml>=6.0"` to dependencies.
**Confirmed by:** Agent3

---

## FALSE POSITIVES (Not Fixed — Verified Correct)

### ~~AssemblyAI auth uses literal `***`~~
**File:** `pipeline/extractors/_shared.py:238,262,282`
**Description:** All 3 agents flagged `f"Authorization: Bearer ***"` as a syntax error. Investigation: the actual code is `f"Authorization: Bearer {api_key}",` — the display tool redacts `{api_key}` to `***`.
**Verification:** `py_compile` passes, `import` succeeds, character-by-character hex dump confirms `{api_key}` is present.
**Lesson:** This is the "API Key Redaction False Positive" documented in multi-agent-code-review skill. Always hex-verify before flagging.

---

## SUMMARY TABLE

| Severity | Found | Fixed | False Positive |
|----------|-------|-------|----------------|
| CRITICAL | 2     | 1     | 1              |
| HIGH     | 5     | 5     | 0              |
| MEDIUM   | 4     | 4     | 0              |
| LOW      | 1     | 1     | 0              |
| **Total**| **12**| **11**| **1**          |

---

## ITEMS NOT FIXED (Noted for Future)

### Architecture: Duplicated `_run_qmd` logic
`pipeline/create.py:concept_convergence()` reimplements qmd query logic from `pipeline/plan.py:_run_qmd()`. Maintenance hazard — bugs fixed in one won't propagate to the other. Recommend extracting to shared `pipeline/qmd.py` module.

### Performance: O(N²) orphan check in stats
`pipeline/stats.py:96-114` scans every file for every entry. Recommend building a single reference index or reusing `lint.py:check_orphaned_notes()`.

### Performance: Sequential concept_search qmd queries
`pipeline/plan.py:concept_search()` runs qmd queries sequentially. Could parallelize with ThreadPoolExecutor.

### Token usage: Insight agent gets 6000 chars
`pipeline/create.py:generate_entry_insights()` truncates content at 6000 chars. Plan prompt uses 8000. Consider increasing to 10000-12000.

### Consistency: Duplicate utility functions
`_escape_yaml` defined in 3 places. `_count_md` duplicated between `compile.py` and `stats.py`. `_extract_frontmatter_field` duplicated between `vault.py` and `stats.py`. Recommend extracting to shared utility.

### Config: Inconsistent hash lengths
`config.py` uses 8-char hashes, `models.py` and `store.py` use 12-char. Standardize to 12.

### Config: No input validation for env vars
`config.py:174-183` uses `int()` without try/except. Non-numeric env vars crash.

### Design: Twitter/PDF source types defined but no extractors
`SourceType.TWITTER` and `SourceType.PDF` exist in models but have no dedicated extractors.

---

## VERIFICATION

```
$ python3 -m pytest tests/ -x --tb=short -q
391 passed in 27.97s

$ python3 -m py_compile pipeline/review.py    # OK
$ python3 -m py_compile pipeline/extract.py    # OK
$ python3 -m py_compile pipeline/extractors/web.py    # OK
$ python3 -m py_compile pipeline/extractors/_shared.py # OK
$ python3 -m py_compile pipeline/compile.py    # OK
$ python3 -m py_compile pipeline/create.py     # OK
$ python3 -m py_compile pipeline/plan.py       # OK
```
