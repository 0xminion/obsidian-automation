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
| L9 | `test_edge_cases.sh:80` | Malformed regex — `\\\\\\\\\\\\\\\\.com` instead of `\\\\.com` |
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

---

# Code Review: Single Source of Truth — Note Formatting

**Reviewer:** Hermes Agent
**Date:** 2026-04-18 (afternoon)
**Scope:** Full codebase review enforcing single source of truth for note formatting across prompts/, templates/, scripts/, lib/, and vault samples
**Method:** Line-by-line comparison of templates, prompts, validators, linters, and 15 vault file samples

---

## Check 1: Template Alignment (templates/ vs prompts/)

### Entry Template vs entry-structure.prompt
- **templates/Entry.md:76** uses "Pros/Cons" (slash) for comparison template, but **prompts/entry-structure.prompt:133** uses "Pros and Cons" (and-separated). Lint and validate also use "Pros and Cons". The template file itself is the outlier.
- Frontmatter fields match between template and prompt (both define `title`, `source`, `date_entry`, `status`, `reviewed`, `review_notes`, `template`, `aliases`, `tags`).
- Section names for all 5 template variants match between template and prompt. ✓

### Concept Template vs concept-structure.prompt
- **templates/Concept.md:13** specifies `status: evergreen` for new concepts.
- **prompts/concept-structure.prompt:15** specifies `status: review` for new concepts. **MISMATCH** — prompts and templates disagree on initial concept status.
- All section names match: Core concept, Context, Links (English); 核心概念, 背景, 关联 (Chinese). ✓

### MoC Template vs moc-structure.prompt
- **templates/MoC.md:27** defines "Bridge Concepts / 桥接概念" as a required section.
- **prompts/moc-structure.prompt** does NOT include Bridge Concepts in its body template. Instead it has topic-specific sections, Cross-References, and Related MoCs only. **MISMATCH** — template says Bridge Concepts is required, prompt omits it.
- **lib/common.sh:14-16** says "NOT ## Bridge Concepts / 桥接概念 with narrative prose" — contradicts the MoC template.
- Section headings format matches: "English / 中文" with topic-specific sections. ✓

**Fix priority:** Reconcile MoC template with common.sh and moc-structure.prompt. Decide if Bridge Concepts is in or out.

---

## Check 2: Prompt Alignment (all prompts reference same section names?)

| Prompt | Entry sections referenced | Concept sections referenced | MoC sections referenced |
|--------|-------------------------|---------------------------|------------------------|
| entry-structure.prompt | Summary, Core insights, Other takeaways, Diagrams, Open questions, Linked concepts ✓ | N/A | N/A |
| concept-structure.prompt | N/A | Core concept, Context, Links ✓ | N/A |
| moc-structure.prompt | N/A | N/A | Overview / 概述, topic sections, Bridge Concepts, Cross-References, Related MoCs ✓ |
| common-instructions.prompt | References entry/concept structures ✓ | Same | MoC headings "English / 中文" ✓ |
| batch-create.prompt | References {ENTRY_STRUCTURE} and {CONCEPT_STRUCTURE} placeholders ✓ | Same | References MOC_TARGETS ✓ |
| compile-pass.prompt | Lines 113-116: lists standard, technical, comparison, procedural sections ✓ | Lines 20, 44: 'Linked concepts' and 'Links' ✓ | Lines 67-83: MoC rebuild structure ✓ |

**Mismatch found:** compile-pass.prompt:115 lists comparison template sections as "Pros/Cons" (slash) — consistent with templates/Entry.md:76 but inconsistent with entry-structure.prompt:133 and validate-output.sh.

**MISMATCH TABLE:**

| File | Line | Comparison Section Name | Correct per which source? |
|------|------|------------------------|--------------------------|
| templates/Entry.md | 76 | Pros/Cons | Outlier — should be "Pros and Cons" |
| entry-structure.prompt | 133 | Pros and Cons | ✓ matches lint/validate |
| validate-output.sh | — | (not checked for comparison) | — |
| lint-vault.sh | 293 | Pros and Cons | ✓ |
| compile-pass.prompt | 115 | Pros/Cons | ✗ matches outlier template |

---

## Check 3: Validator Alignment (validate-output.sh)

### Entry section checks (lines 142-169)

| Template | Sections checked in validate-output.sh | Sections defined in template | Match? |
|----------|---------------------------------------|------------------------------|--------|
| standard/chinese | Summary, Core insights, Other takeaways, Open questions, Linked concepts | Summary, Core insights, Other takeaways, Diagrams, Open questions, Linked concepts | ⚠️ Diagrams optional but not tracked |
| technical | Summary, Key Findings, Data/Evidence, Limitations, Linked concepts | Summary, Key Findings, Data/Evidence, **Methodology**, Limitations, Linked concepts | ❌ MISSING "Methodology" |
| comparison | (no check found — `case` falls through) | Summary, Side-by-Side Comparison, Pros and Cons, Verdict, Linked concepts | ❌ MISSING ENTIRELY |
| procedural | Summary, Steps, Linked concepts | Summary, Prerequisites, Steps, Gotchas, Linked concepts | ⚠️ Missing Prerequisites, Gotchas |

**Mismatches:**
- **validate-output.sh:156** — Technical template check missing "Methodology" section
- **validate-output.sh:144** — Chinese template lumped with standard; no `language: zh` validation
- **validate-output.sh** — Comparison template has NO section validation at all
- **validate-output.sh** — Procedural template only checks 3 of 5 sections

### Concept section checks (lines 173-204)
- English: Core concept, Context, Links ✓
- Chinese: 核心概念, 背景, 关联 ✓
- **ISSUE:** Does not detect `language: zh` properly (uses python fallback to "en" if YAML parse fails)

### MoC section checks (lines 207-222)
- Checks for "Overview / 概述" ✓
- Checks minimum 2 sections total (Overview + at least 1 topic) ✓
- **ISSUE:** Does not check for Related MoCs section, Cross-References, or Bridge Concepts

---

## Check 4: Linter Alignment (lint-vault.sh)

### Entry template checks (lines 268-349)

| Template | Sections checked | Match with template? |
|----------|-----------------|---------------------|
| standard | Summary, Core insights, Other takeaways, Diagrams, Open questions, Linked concepts | ✓ All 6 checked |
| technical | Summary, Key Findings, Data/Evidence, Methodology, Limitations, Linked concepts | ✓ All 6 checked |
| comparison | Summary, Side-by-Side Comparison, Pros and Cons, Verdict, Linked concepts | ✓ All 5 checked |
| procedural | Summary, Prerequisites, Steps, Gotchas, Linked concepts | ✓ All 5 checked |
| chinese | 摘要, 核心发现, 其他要点, 图表, 开放问题, 关联概念 | ✓ All 6 checked |
| bilingual | Summary / 摘要, Key Insights / 关键洞察, Diagrams / 图表, Open Questions / 开放问题, Linked Concepts / 关联概念 | ✓ (no template exists for this) |

**Lint is MORE thorough than validate-output.sh** — lint checks all sections for all templates, validate misses Methodology, comparison, and full procedural checks.

**However:** lint-vault.sh includes a "bilingual" template check (line 313-318) that has no corresponding template in templates/Entry.md, templates/agents.md, or entry-structure.prompt. This is a phantom check.

---

## Check 5: MoC Format Consistency

### Template (templates/MoC.md)
Defines: Overview / 概述, Topic Sections, Bridge Concepts / 桥接概念, Cross-References / 关联图谱, Related MoCs / 关联图谱
**Topic-specific sections** (not language-split). ✓

### Prompts
- moc-structure.prompt: Topic-specific sections, Overview, Cross-References, Related MoCs. NO Bridge Concepts. ✓ (topic-specific)
- compile-pass.prompt:67-83: Same structure with Overview, topic sections, Bridge Concepts, Cross-References, Related MoCs. ✓
- common-instructions.prompt:83-85: Mentions "section headers to separate language groups" — **CONTRADICTS** topic-specific format.

### Validators
- validate-output.sh: Only checks Overview + minimum section count. Does NOT enforce topic-specific format.
- lint-vault.sh: No MoC-specific section validation beyond orphan/broken checks.

### Vault samples
All 5 sampled MoCs use **topic-specific sections**, not language-split. ✓
- prediction-markets.md: "Core Mechanisms / 核心机制", "Platform Critiques / 平台批判", etc.
- Trading Strategies: "Manipulation Shorting / 操纵做空"
- AI Engineering: "Harness Engineering / 约束工程", "Agent Architecture / Agent架构"

**Verdict:** MoCs correctly use topic-specific format in practice. But common-instructions.prompt:83-85 still has outdated language-split instructions that could confuse agents.

---

## Check 6: Vault Conformity

### Entries sampled (5)

| File | Issues |
|------|--------|
| Meteora and the Thesis... | ✓ Conforms to standard template |
| Harness Engineering - A Recurring Pattern | `reviewed: null` should be `""` per template |
| 妖币做空策略... | ✓ Conforms to chinese template |
| regulating-prediction-markets-in-europe.md | `entry_type: standard` (should be `template: standard`), `reviewed: false` (should be `""`), missing `review_notes`, missing `aliases`, extra non-standard sections (Overview, Key Topics, Context, Implications), only 5 tags (template says minimum 5+entry), `entry` tag missing |
| Slate Skill Chaining Architecture... | Missing `template:` field, `status: draft` (not in template spec), `reviewed: null` (should be `""`), missing blank line after H1, `source_type: twitter` (non-standard field) |

### Concepts sampled (5)

| File | Issues |
|------|--------|
| Harness Engineering | `created`/`last_updated` instead of `date_created`/`date_updated` per template, `reviewed: null`, missing `type: concept` frontmatter field |
| Prediction Market Game Theory | Missing `type: concept`, missing `status: evergreen`, missing `date_created`/`date_updated` |
| 妖币交易策略 | ✓ Conforms to chinese concept template |
| Agent友好协议设计 | Links section named "链接" not "关联" per Chinese template |
| DeFi Yield Dynamics | Missing `type: concept`, missing `status: evergreen`, missing `date_created`/`date_updated` |

### MoCs sampled (5)

| File | Issues |
|------|--------|
| prediction-markets.md | ✓ Conforms |
| Trading Strategies / 交易策略 | `created`/`last_updated` instead of `date_created`/`date_updated`, tag `moc` not `map-of-content` |
| AI Engineering / AI工程实践 | ✓ Conforms |
| crypto-market-mechanics.md | ✓ Conforms |
| Consciousness & AI / 意识与人工智能 | Tag `moc` not `map-of-content`, `last_updated` not `date_updated` |

**Summary:** 3/5 entries conform, 2/5 concepts conform, 3/5 MoCs conform. Main pattern: frontmatter field name drift (`created` vs `date_created`, `reviewed: null` vs `reviewed: ""`).

---

## Check 7: Version Consistency

| File | Version | Status |
|------|---------|--------|
| templates/agents.md:1 | v2.1.0 | ✅ |
| prompts/common-instructions.prompt:2 | v2.1.0 | ✅ |
| scripts/validate-output.sh:3 | v2.1.0 | ✅ |
| scripts/lint-vault.sh:3 (header) | v2.1.0 | ✅ |
| scripts/lint-vault.sh:27 (report body) | v2.0.1 | ❌ STALE |
| scripts/lint-vault.sh:599 (report footer) | v2.0.1 | ❌ STALE |
| lib/common.sh:3 | v2.1.0 | ✅ |

**Two stale version strings** in lint-vault.sh:27,599 — report says "v2.0.1" but script is v2.1.0.

---

## Check 8: agents.md Alignment

**templates/agents.md** describes note structures that are ALIGNED with current templates:
- Entry: standard (Summary, Core insights, Other takeaways, Diagrams, Open questions, Linked concepts) ✓
- Entry: chinese (摘要, 核心发现, 其他要点, 图表, 开放问题, 关联概念) ✓
- Entry: technical, comparison, procedural ✓
- Concept: Core concept, Context, Links ✓
- Concept Chinese: 核心概念, 背景, 关联 ✓
- MoC: Topic-specific sections, Overview, Bridge Concepts, Cross-References, Related MoCs ✓
- Formatting rules (H1, blank lines) ✓

**One inconsistency:** agents.md:239 lists "Related MoCs / 关联图谱" but MoC template line 34 has the same Chinese label for both Cross-References AND Related MoCs ("关联图谱" used twice). This is a template bug, not an agents.md bug.

**Verdict:** agents.md is CURRENT and describes the correct structure. No outdated format found.

---

## Single Source of Truth Conflicts Summary

| # | Conflict | Files | Resolution Needed |
|---|----------|-------|-------------------|
| 1 | Comparison section name "Pros/Cons" vs "Pros and Cons" | templates/Entry.md:76 vs entry-structure.prompt:133, lint-vault.sh:293 | Standardize on "Pros and Cons" |
| 2 | Concept initial status: `evergreen` vs `review` | templates/Concept.md:13 vs concept-structure.prompt:15 | Standardize on `evergreen` |
| 3 | MoC "Bridge Concepts" section: required vs forbidden | templates/MoC.md:27 vs lib/common.sh:14 vs moc-structure.prompt | Decide: in or out |
| 4 | validate-output.sh missing "Methodology" for technical | validate-output.sh:156 vs templates/Entry.md:72 | Add Methodology to check |
| 5 | validate-output.sh missing comparison template check | validate-output.sh vs templates/Entry.md:75-76 | Add comparison case |
| 6 | common-instructions.prompt:83 language-split MoC instructions | common-instructions.prompt vs templates/MoC.md, common.sh | Remove language-split instructions |
| 7 | lint-vault.sh phantom "bilingual" template check | lint-vault.sh:313-318 vs templates/ (no bilingual template) | Remove or create template |
| 8 | lint-vault.sh v2.0.1 in report vs v2.1.0 actual | lint-vault.sh:27,599 vs lint-vault.sh:3 | Update to v2.1.0 |
| 9 | MoC template uses "关联图谱" for both Cross-Refs AND Related MoCs | templates/MoC.md:31,34 | Use distinct Chinese labels |
| 10 | Frontmatter field naming drift in vault | vault files vs templates | Standardize on `date_created`/`date_updated` |

---

## Recommended Actions

1. **Make templates/ the single source of truth.** All prompts, validators, and linters must derive section names from templates/.
2. **Fix validate-output.sh** to match lint-vault.sh's thoroughness — add Methodology, comparison, full procedural, and Chinese template checks.
3. **Remove Bridge Concepts from MoC template** or add it to moc-structure.prompt — reconcile the conflict.
4. **Fix common-instructions.prompt:83-85** — remove outdated language-split MoC instructions.
5. **Fix concept-structure.prompt:15** — change `status: review` to `status: evergreen` per template.
6. **Fix templates/Entry.md:76** — change "Pros/Cons" to "Pros and Cons".
7. **Fix templates/MoC.md:31,34** — use distinct Chinese labels for Cross-References vs Related MoCs.
8. **Unify version strings** in lint-vault.sh:27,599 to v2.1.0.
9. **Remove lint-vault.sh bilingual check** or create a corresponding template.
10. **Fix vault files** with non-standard frontmatter (field names, reviewed type, missing fields).

---

*This section supersedes formatting-related findings. Runtime bugs (C1-C4, H1-H7, M1-M9) in the main review above remain unchanged.*

---

# Code Review: Documentation, Skills & Vault Audit

**Reviewer:** Agent 2 (Hermes)
**Date:** 2026-04-18
**Scope:** README.md, PRD.md, skills/, obsidian-automation-conventions skill, full vault audit (162 entries, 104 concepts, 23 MoCs, 153 sources)
**Method:** Automated grep/awk across all vault files, line-by-line doc review

---

## 1. README.md Accuracy

| Check | Result |
|-------|--------|
| References v2 pipeline (not v1) | ✅ Correct — "v2.1.0", 3-stage pipeline |
| Script paths correct | ✅ All `scripts/*.sh` paths verified |
| Section names match templates | ✅ Standard/chinese entry sections match |
| MoC format mentions topic-specific | ✅ Line 83: "organize by theme, language, or time period" |

**No issues found.** README is accurate and current.

---

## 2. PRD.md Accuracy

| Check | Result |
|-------|--------|
| Same note structures as templates | ✅ Entry/concept/MoC structures match |
| MoC format described correctly | ✅ "Flexible section structure" — matches practice |

**No issues found.** PRD is accurate and current.

---

## 3. Skills Consistency

### `skills/obsidian-ingest.md`

| Check | Result |
|-------|--------|
| Version matches codebase | ✅ v2.1.0 (fixed from 3.0.0 per Agent 1 C4) |
| Pipeline reference correct | ✅ 3-stage: Extract → Plan → Create |
| Note structures match templates | ✅ Standard/technical/chinese sections match |
| Hardcoded paths | ⚠️ Lines 19-20: `/home/linuxuser/...` instead of `$HOME` (Agent 1 L4) |

### `~/.hermes/skills/obsidian-automation-conventions/SKILL.md`

**❌ MISSING ENTIRELY.** The `~/.hermes/skills/` directory is empty — no skills installed at all. The `obsidian-automation-conventions` skill referenced in the task scope does not exist. This means no global conventions skill is available for agents working outside the repo.

**Fix:** Create `~/.hermes/skills/obsidian-automation-conventions/SKILL.md` with vault conventions, or confirm this skill is intentionally not installed.

---

## 4. Vault Audit (ALL files in 04-Wiki/)

### 4a. MoCs with old-format headers
`## English Resources`, `## 中文资源`, `## Core Entries`, `## Related Concepts`

**✅ None found.** All 23 MoCs use topic-specific bilingual format (e.g., "## Core Mechanisms / 核心机制").

### 4b. MoCs with `## Open Questions` or `## Open Threads`

**✅ None found.** These sections have been fully removed.

### 4c. Chinese concepts missing `language: zh` frontmatter

**✅ None found.** All 40 Chinese-language concept files have `language: zh`. (13 English concepts that reference Chinese MoC titles in wikilinks were false positives — body text is English.)

### 4d. Wrong section headers (case-sensitive)

**✅ None found.** No instances of "Open Questions" (capital Q), "Other Takeaways" (capital T), "Core Insights" (capital I), or "Linked Concepts" (capital C). All section headers use correct lowercase format.

### 4e. Files with `null` in YAML frontmatter

**❌ 30 entries + 12 concepts use `reviewed: null` or `review_notes: null` instead of `\"\"`.**

Entries with `reviewed: null` or `review_notes: null` (30 files):

- entries/How Study Design Affects Outcomes in Comparisons of Therapy. I: Medical.md
- entries/AI Agent Memory Systems Benchmark Comparison 2024-2026.md
- entries/Professor Jiang - Intellectually Arousing YouTube Content.md
- entries/DeFi Lending Rate Compression Through Democratized Capital Supply.md
- entries/Death by Meritocracy - How Elite Universities Reshape Society.md
- entries/Internal DAO Memo - MegaMafia Founders Note.md
- entries/Kalshi Sports Prediction Markets Growth and Structure Analysis.md
- entries/卖空权与山寨牛市：交易机制进化如何引爆繁荣.md
- entries/Crypto AI Research - Stablecoins DeFi and Beyond.md
- entries/Harness Engineering - A Recurring Pattern.md
- entries/Xiaomi MiMo - The Underrated AI Model with Hardware Integration Advantage - 0xjiawei.md
- entries/The Cost of Cynicism - From Social Media Addiction to Spiritual Redemption - WillManidis.md
- entries/Nic Carter on Stablecoin and Banking Integration.md
- entries/Skills as Dynamic Actions - Reimagining AI Agent Capabilities.md
- entries/Ruled by Precession - Buckminster Fuller and Perpendicular Returns.md
- entries/Modeling the AGI Economy - General Equilibrium and Policy Levers.md
- entries/Psychedelic Drugs and Resting-State Neural Mechanisms.md
- entries/Game Theory Formulas for Prediction Market Trading.md
- entries/Complexity Implies Singularities Are Impossible.md
- entries/Taste as Vocabulary - Developing Aesthetic Literacy in the AI Era - itsjessyin.md
- entries/Traitors Among Us - Crypto Conference Culture.md
- entries/MEV Solved - Reframing Transaction Ordering as Transaction Ordering Value.md
- entries/Harness Engineering Critique - Beyond Coining Buzzwords.md
- entries/Building Facebook in a Weekend with a $20 AI Subscription.md
- entries/OI-PoR交易所分析：杠杆劫持计划.md
- entries/GPU Debt Financing - The Hidden Financial Infrastructure of AI Hardware - 0xZergs.md
- entries/Game Theory #20 - Mid-Term Examination.md
- entries/Slate Skill Chaining Architecture for AI Agents.md
- entries/NPC Consciousness and Firmware Metaphor.md
- entries/AI Agent Ecosystem - Memory Skills and Hardware Integration.md

Concepts with `reviewed: null` (12 files):
- concepts/Harness Engineering.md
- concepts/Physiological Armoring.md
- concepts/Psychedelic Neural Mechanisms.md
- concepts/Oxidized Lipid Theory of Sleep.md
- concepts/Singularity Impossibility via Complexity.md
- concepts/Wolverine Stack.md
- concepts/BPC-157 Peptide Therapy.md
- concepts/AI Democratized Software Development.md
- concepts/Crypto AI Infrastructure.md
- concepts/Crypto-to-AI Talent Migration.md
- concepts/China AI Ecosystem.md
- concepts/NPC Consciousness Theory.md

**Fix:** `validate-output.sh --fix` should handle this, or bulk sed: `sed -i 's/reviewed: null/reviewed: ""/g; s/review_notes: null/review_notes: ""/g'`

### 4f. Entries missing H1 title or missing blank line after H1

**Missing H1:** ✅ None — all files have `# Title` after YAML frontmatter.

**Missing blank line after H1: ❌ 16 entries:**

- entries/AI Agent Memory Systems Benchmark Comparison 2024-2026.md
- entries/DeFi Lending Rate Compression Through Democratized Capital Supply.md
- entries/Death by Meritocracy - How Elite Universities Reshape Society.md
- entries/GPU Debt Financing - The Hidden Financial Infrastructure of AI Hardware - 0xZergs.md
- entries/Game Theory Formulas for Prediction Market Trading.md
- entries/Harnessing Boredom for Productivity and Personal Growth - Tim Denning.md
- entries/Kalshi Sports Prediction Markets Growth and Structure Analysis.md
- entries/MEV Solved - Reframing Transaction Ordering as Transaction Ordering Value.md
- entries/Modeling the AGI Economy - General Equilibrium and Policy Levers.md
- entries/Nic Carter on Stablecoin and Banking Integration.md
- entries/Ruled by Precession - Buckminster Fuller and Perpendicular Returns.md
- entries/Skills as Dynamic Actions - Reimagining AI Agent Capabilities.md
- entries/Slate Skill Chaining Architecture for AI Agents.md
- entries/Taste as Vocabulary - Developing Aesthetic Literacy in the AI Era - itsjessyin.md
- entries/The Cost of Cynicism - From Social Media Addiction to Spiritual Redemption - WillManidis.md
- entries/Xiaomi MiMo - The Underrated AI Model with Hardware Integration Advantage - 0xjiawei.md

**Fix:** Add blank line after each `# Title` line.

---

## 5. Template vs Vault Alignment

### Frontmatter field naming drift

**Concepts/MoCs date fields:**
- 74 files use `created:`/`last_updated:` (old format)
- 69 concepts + 20 MoCs = 89 files use `date_created:`/`date_updated:` (correct per template)

3 MoCs mix both formats (e.g., `Crypto Regulation - 加密监管.md`, `Ethereum Ecosystem - 以太坊生态.md`, `Research Methods.md` use `created:` instead of `date_created:`).

**Entries:** All 162 entries use `date_entry:` (consistent within entries, different from concepts/MoCs — this appears intentional).

### `entry_type:` vs `template:` field

**❌ 4 entries use `entry_type:` instead of `template:`:**

- entries/how-manipulable-are-prediction-markets.md: `entry_type: paper`
- entries/perpetual-attention-markets-on-monad.md: `entry_type: standard`
- entries/regulating-prediction-markets-in-europe.md: `entry_type: standard`
- entries/wisdom-of-crowds-prediction-markets.md: `entry_type: paper`

**Fix:** Rename field to `template:`.

### Entries missing `template:` field entirely

**❌ 20 entries have no `template:` or `entry_type:` field:**

- entries/AI Agent Memory Systems Benchmark Comparison 2024-2026.md
- entries/DeFi Lending Rate Compression Through Democratized Capital Supply.md
- entries/Death by Meritocracy - How Elite Universities Reshape Society.md
- entries/GPU Debt Financing - The Hidden Financial Infrastructure of AI Hardware - 0xZergs.md
- entries/Game Theory Formulas for Prediction Market Trading.md
- entries/Harnessing Boredom for Productivity and Personal Growth - Tim Denning.md
- entries/Kalshi Sports Prediction Markets Growth and Structure Analysis.md
- entries/MEV Solved - Reframing Transaction Ordering as Transaction Ordering Value.md
- entries/Modeling the AGI Economy - General Equilibrium and Policy Levers.md
- entries/Nic Carter on Stablecoin and Banking Integration.md
- entries/Ruled by Precession - Buckminster Fuller and Perpendicular Returns.md
- entries/Skills as Dynamic Actions - Reimagining AI Agent Capabilities.md
- entries/Slate Skill Chaining Architecture for AI Agents.md
- entries/Taste as Vocabulary - Developing Aesthetic Literacy in the AI Era - itsjessyin.md
- entries/The Cost of Cynicism - From Social Media Addiction to Spiritual Redemption - WillManidis.md
- entries/Xiaomi MiMo - The Underrated AI Model with Hardware Integration Advantage - 0xjiawei.md
- entries/how-manipulable-are-prediction-markets.md
- entries/perpetual-attention-markets-on-monad.md
- entries/regulating-prediction-markets-in-europe.md
- entries/wisdom-of-crowds-prediction-markets.md

**Note:** These 20 entries are the same files missing blank lines after H1 and many have `reviewed: null` — they appear to be older entries predating the v2 template enforcement.

### Template section mismatches (entries with `template:` set)

**❌ 7 standard entries missing `## Other takeaways`:**

- entries/Don't take me wrong..md
- entries/This is not another clickbait.md
- entries/everyones-promising-20x-leverage-on-prediction-markets.md
- entries/perpetual-attention-markets-monad.md
- entries/polymarket-is-not-a-truth-machine.md
- entries/prediction-markets-as-information-aggregation-mechanisms-a16z.md
- entries/（注：头图为美国著名画家郭白石(Grok · Baitshit)的国画作品《愿者上勾》.md (chinese template, missing 其他要点)

### MoC tag inconsistency

**❌ 10 MoCs use tag `moc` instead of `map-of-content`:**

- AI & Software Engineering - AI与软件工程.md
- AI Education - AI教育资源.md
- AI Geopolitics - AI地缘格局.md
- Biohacking & Longevity - 生物黑客与长寿.md
- Consciousness & AI - 意识与人工智能.md
- Crypto Regulation - 加密监管.md
- Ethereum Ecosystem - 以太坊生态.md
- Geopolitics & Strategy - 地缘政治与战略.md
- Neuroscience Research - 神经科学研究.md
- Sleep Science - 睡眠科学.md

**13 MoCs correctly use `map-of-content`.**

### Chinese concept section name mismatch

**❌ 1 concept uses `## 链接` instead of `## 关联` per template:**

- concepts/Agent友好协议设计.md: Uses `## 链接` (should be `## 关联`)

### Bridge Concepts section in MoCs

**⚠️ Inconsistency across MoCs — 6 MoCs have `## Bridge Concepts / 桥接概念`, 17 don't.**
This aligns with Agent 1's finding: template says required, but moc-structure.prompt omits it. Vault practice is mixed.

---

## Summary of All Issues Found

| Severity | Count | Category |
|----------|-------|----------|
| ❌ High | 42 | `null` values in frontmatter (`reviewed: null`, `review_notes: null`) |
| ❌ High | 20 | Entries missing `template:` field entirely |
| ❌ High | 4 | Entries using `entry_type:` instead of `template:` |
| ❌ High | 16 | Entries missing blank line after H1 |
| ❌ High | 1 | `~/.hermes/skills/obsidian-automation-conventions/SKILL.md` missing |
| ⚠️ Medium | 74 | Concepts/MoCs using `created/last_updated` instead of `date_created/date_updated` |
| ⚠️ Medium | 10 | MoCs using tag `moc` instead of `map-of-content` |
| ⚠️ Medium | 7 | Entries missing required template sections |
| ⚠️ Low | 1 | Chinese concept uses `## 链接` instead of `## 关联` |
| ⚠️ Low | 6 | MoCs with Bridge Concepts section (inconsistent with prompt) |
| ✅ Clean | — | No old-format MoC headers (English Resources, 中文资源, etc.) |
| ✅ Clean | — | No Open Questions/Threads in MoCs |
| ✅ Clean | — | No Chinese concepts missing `language: zh` |
| ✅ Clean | — | No case-sensitive section header errors |
| ✅ Clean | — | README.md and PRD.md accurate |

---

## Fix Priority

1. **Bulk-fix `null` → `\"\"`** in frontmatter (42 files) — `sed -i 's/: null/: ""/g'`
2. **Add `template: standard`** to 20 orphan entries
3. **Rename `entry_type:` → `template:`** in 4 entries
4. **Add blank line after H1** in 16 entries
5. **Standardize date fields**: `created/last_updated` → `date_created/date_updated` (74 files)
6. **Fix MoC tags**: `moc` → `map-of-content` (10 files)
7. **Create `~/.hermes/skills/obsidian-automation-conventions/SKILL.md`** or confirm omission
8. **Fix `## 链接` → `## 关联`** in concepts/Agent友好协议设计.md
9. **Reconcile Bridge Concepts** — decide if it's in or out of MoC template

---

*This review covers documentation, skills, and vault audit only. Runtime bugs (C1-C4, H1-H7, M1-M9) and single-source-of-truth conflicts (Check 1-10) from Agent 1's review above remain unchanged.*
