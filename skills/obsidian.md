---
name: obsidian
description: "Process any URL, file, or link into the Obsidian vault. Drop URLs in chat, pipeline handles extraction + wiki creation."
version: 3.0.0
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

If orchestrator fails, run stages manually: `stage1-extract.sh` → `stage2-plan.sh` → `stage3-create.sh --parallel 3`

## Pipeline

Three stages (see scripts for details):
- **Stage 1 — Extract** (shell, no agent): Parallel extraction. Output: `/tmp/extracted/manifest.json`
- **Stage 2 — Plan** (1 agent): Semantic concept matching. Output: `/tmp/extracted/plans.json`
- **Stage 3 — Create** (N agents, parallel): Writes Source → Entry → Concept → MoC files

Options: `--parallel N` (default 3), `--vault PATH`

## Note Structures

Check `template:` frontmatter field. Default `standard`.

| Template | Sections |
|----------|----------|
| standard (EN) | Summary → Core insights → Other takeaways → Diagrams → Open questions → Linked concepts |
| chinese (ZH) | 摘要 → 核心发现 → 其他要点 → 图表 → 开放问题 → 关联概念 |
| technical | Summary → Key Findings → Data/Evidence → Methodology → Limitations → Linked concepts |

**Concepts** (evergreen): Core concept → Context (flowing prose, no sub-headings) → Links
**MoCs**: Entries mixed under bilingual heading. Cross-References with ASCII diagram. No language sub-headings.

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
6. Stage 3 timeout ≠ failure — check vault before re-running
7. Extraction: curl for APIs (Python urllib gets 403). See `lib/extract.sh` header for platform table.
