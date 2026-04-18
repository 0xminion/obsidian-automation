---
name: obsidian-ingest
description: "Process any URL, file, or link into the Obsidian vault. Drop URLs in chat, pipeline handles extraction + wiki creation."
version: 2.1.0
trigger: "obsidian"
---

# Obsidian Vault Processor

User says "obsidian" + URLs/files → write to inbox → run pipeline. The codebase handles everything else.

## Workflow

```bash
# 1. Write URLs to inbox (one .url file per URL)
echo "$URL" > "$VAULT_PATH/01-Raw/$SANITIZED.url"

# 2. Run pipeline
cd /home/linuxuser/workspaces/gamma/obsidian-automation
VAULT_PATH=/home/linuxuser/MyVault bash scripts/process-inbox.sh

# 3. After pipeline: archive, reindex, sync
mkdir -p "$VAULT_PATH/01-Raw/archive" && mv "$VAULT_PATH/01-Raw/"*.url "$VAULT_PATH/01-Raw/archive/"
bash scripts/reindex.sh && ob sync --path "$VAULT_PATH"
```

If orchestrator fails, run stages manually — **must set PIPELINE_TMPDIR** so stages share the same temp dir:
```bash
# Get the temp dir process-inbox.sh created (or create one)
HASH=$(echo -n "$VAULT_PATH" | md5sum | cut -c1-8)
export PIPELINE_TMPDIR="/tmp/obsidian-extracted-${HASH}"

# If stage 1 already ran (check for manifest), skip to stage 2+3
# Otherwise run all three:
cd /home/linuxuser/workspaces/gamma/obsidian-automation
VAULT_PATH=/home/linuxuser/MyVault bash scripts/stage1-extract.sh
VAULT_PATH=/home/linuxuser/MyVault bash scripts/stage2-plan.sh
VAULT_PATH=/home/linuxuser/MyVault bash scripts/stage3-create.sh --parallel 3

# Post-processing (stage 3 does this internally, but do it manually if stage 3 timed out):
bash scripts/reindex.sh && ob sync --path "$VAULT_PATH"
```

### YouTube Transcript Chain (batch pipeline)

`stage1-extract.sh` has a 3-step fallback chain (v2.2.0+):
1. **TranscriptAPI** (primary) — requires `TRANSCRIPT_API_KEY` in `.env`
2. **Supadata** (fallback) — requires `SUPADATA_API_KEY` in `.env`
3. **faster-whisper** (last resort) — uses `yt-dlp` + `faster-whisper` Python module, no API key needed

Without API keys, steps 1-2 silently skip and step 3 runs (slower, ~2-5 min per video).
If all 3 fail, extraction saves metadata-only content (~182 chars) and reports "OK" — check content length to detect this.

## Pipeline

Three stages (see scripts for details):
- **Stage 1 — Extract** (shell, no agent): Parallel extraction. Output: `/tmp/extracted/manifest.json`
- **Stage 2 — Plan** (1 agent): Semantic concept matching. Output: `/tmp/extracted/plans.json`
- **Stage 3 — Create** (N agents, parallel): Writes Source → Entry → Concept → MoC files

Options: `--parallel N` (default 3), `--vault PATH`

### Timeouts

Stage 1-2 are fast (seconds to ~1 min). **Stage 3 spawns hermes agents with a 900s internal timeout each.** When calling from terminal:
- `terminal()` timeout must be ≥ 960s (900 + overhead)
- For `--parallel N`, worst case is still 900s (batches run concurrently)
- If terminal timeout < 900s, the parent shell gets killed, background agents become orphaned, and post-processing (reindex, archive, sync) never runs — but the agent may have already written files

Stage 2 also calls `qmd` per plan with 300s timeout. Budget ~400s for stage 2 if calling manually.

## Pitfalls

### Stage 3 timeout looks like failure but isn't

**Root cause:** Terminal timeout < 900s agent timeout. The parent shell dies, background agent keeps running orphaned, `wait` never returns, post-processing (validate → reindex → log → archive → sync) is skipped.

**Symptoms:** "Terminated" in output, exit code 124, but vault may have new files.

**Diagnosis:**
```bash
# Check if agent wrote files despite timeout
find $VAULT_PATH/04-Wiki -newer /tmp/extracted/manifest.json -name "*.md"
# Check if agent finished its work
cat /tmp/extracted/batch_0_output.txt | tail -20
```

**Fix:** Re-run stage 3 directly with PIPELINE_TMPDIR set. Files already created won't be overwritten (collision check). Or just run the post-processing manually:
```bash
bash scripts/reindex.sh && ob sync --path $VAULT_PATH
```

## Note Structures

Check `template:` frontmatter field. Default `standard`.

| Template | Sections |
|----------|----------|
| standard (EN) | Summary → Core insights → Other takeaways → Diagrams → Open questions → Linked concepts |
| chinese (ZH) | 摘要 → 核心发现 → 其他要点 → 图表 → 开放问题 → 关联概念 |
| technical | Summary → Key Findings → Data/Evidence → Methodology → Limitations → Linked concepts |

**Concepts** (evergreen): Core concept → Context (flowing prose, no sub-headings) → Links
**MoCs**: Topic-specific bilingual sections (e.g., `Funding Rates / 资金费率`). NOT language-split (no English Resources / 中文资源). NO Open Questions. Cross-References with ASCII diagram. Bridge Concepts + Related MoCs.

## Naming

Source filenames = content title. See `title_to_filename()` in `lib/common.sh`.

- Chinese → Chinese. Papers → paper title. English → kebab-case.
- Tweets → topic, not tweet ID. YouTube → video title. Podcasts → episode title.
- ❌ NEVER: URL slugs, platform prefixes, author handles as filename

## Critical Rules

1. No stubs — every section needs real content
2. Tags: topic-specific English only (never `x.com`, `tweet`, `source`)
3. YAML: quote wikilinks (`source: "[[note]]"`), no nulls (`""` not `null`), quote titles with colons
4. Chinese body stays Chinese — English YAML/tags only
5. After pipeline: check for duplicates (`ls sources/ | sort | uniq -d`)
6. Stage 3 timeout ≠ failure — the agent has 900s budget. Terminal timeout must be ≥ 960s. Check vault for new files before re-running; collision check prevents duplicates.
7. Extraction: curl for APIs (Python urllib gets 403). See `lib/extract.sh` header for platform table.
