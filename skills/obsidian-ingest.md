---
name: obsidian-batch-ingest
description: "Operational guide for batch ingesting URLs into Obsidian vault. Pipeline code is the source of truth — this skill covers extraction chains, file naming, and formatting rules."
version: 3.0.0
---

# Obsidian Batch Ingest — Operational Guide

**The codebase is the source of truth.** This skill covers extraction behavior, naming conventions, and formatting rules that aren't obvious from reading the scripts.

## Quick Start

```bash
# Write URLs to inbox, run pipeline
echo "$URL" > "$VAULT_PATH/01-Raw/$SANITIZED.url"
cd /home/linuxuser/workspaces/gamma/obsidian-automation
VAULT_PATH=/home/linuxuser/MyVault bash scripts/process-inbox.sh

# After pipeline: archive, reindex, sync
mkdir -p "$VAULT_PATH/01-Raw/archive" && mv "$VAULT_PATH/01-Raw/"*.url "$VAULT_PATH/01-Raw/archive/"
bash scripts/reindex.sh && ob sync --path "$VAULT_PATH"
```

If the orchestrator fails, run stages manually: `stage1-extract.sh` → `stage2-plan.sh` → `stage3-create.sh --parallel 3`.

## Extraction Chains

What actually works for each platform (learned from failures):

| Platform | Primary | Fallback | Notes |
|----------|---------|----------|-------|
| YouTube | TranscriptAPI (curl, full URL) | Supadata (POST JSON) | Python urllib gets 403. Pass full URL not bare video_id. |
| Apple Podcasts | iTunes Lookup → RSS → Whisper | RSS description (2-5K chars) | Needs `yt-dlp` for audio download. |
| X/Twitter | defuddle | liteparse → browser | tavily extract always fails on X. |
| arxiv.org | arxiv HTML (defuddle) | alphaxiv.org/abs/ID.md | Use HTML version not abs. |
| Blogs | defuddle | liteparse → browser | Medium/CF-blocked: use tavily MCP. |

## File Naming

**Source filenames = content title.** Baked into `lib/common.sh` `title_to_filename()`.

- Chinese → Chinese (潮汕钱庄与东南亚黑金网络...)
- Papers → paper title (not arxiv ID)
- English → kebab-case lowercase
- Tweets → topic/sentence (not tweet ID)
- YouTube → video title (not video ID)
- Podcasts → episode title
- ❌ NEVER: URL slugs, platform prefixes, author handles as filename

## MoC Format (CRITICAL)

**Entries are mixed under a single bilingual heading.** NO `### English` / `### 中文` sub-headings. NO `## English Resources` / `## Chinese Resources` separation.

```markdown
## Core Entries / 核心条目
- [[English Entry]] — description
- [[中文条目]] — 描述

## Cross-References / 关联图谱
\```
Topic A → connects to → Topic B → influences → Topic C

Cross-links: [[other-moc]] (relationship)
\```
```

NOT `## Bridge Concepts / 桥接概念` with prose. Use `## Cross-References / 关联图谱` with ASCII diagram + cross-links.

## Entry Structure

**English** (template: standard): Summary → Core insights (numbered) → Other takeaways → Diagrams (optional) → Open questions → Linked concepts

**Chinese** (template: chinese): 摘要 → 核心发现 (numbered) → 其他要点 → 图表 (optional) → 开放问题 → 关联概念

## Critical Rules

1. NEVER stubs — every section needs real content
2. Tags: topic-specific English only (never `x.com`, `tweet`, `source`)
3. YAML wikilinks quoted: `source: "[[note]]"`
4. YAML nulls break Obsidian: use `""` not `null`
5. Quotes in YAML titles: `title: "Title: With Colon"`
6. Chinese body stays Chinese — English YAML/tags only
7. After pipeline: check for duplicates (`ls sources/ | sort | uniq -d`)
8. Stage 3 timeout ≠ failure — check vault before re-running

## Pitfalls

- **Plan agent skips real content**: May judge 15K essays as "emotional/personal tweet" if preview starts casually. Check `plan_output.txt` for `_skip: true`.
- **Stale lock**: `rmdir /tmp/obsidian-*.lock` (directories, not files)
- **TranscriptAPI/Supadata**: Always use `curl`, never Python `urllib` (403)
- **Bash arg limit**: Write large content to temp file, pass path to Python
- **Hermes pipeline agents**: Must use `hermes chat -q "$prompt" -Q` (non-interactive). Never `<<< "$prompt"` heredoc.
