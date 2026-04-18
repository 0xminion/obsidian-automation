---
name: obsidian
description: "Process any URL, file, or link into the Obsidian vault. Drop URLs in chat, pipeline handles extraction + wiki creation."
version: 2.1.0
trigger: "obsidian"
---

# Obsidian Vault Processor

When the user says "obsidian" + URLs/files, write them to `$VAULT_PATH/01-Raw/` inbox and run the pipeline. The codebase handles everything else.

## Trigger

User message contains "obsidian" AND a URL or file path.

## Workflow

```bash
# 1. Write URLs to inbox
echo "$URL" > "$VAULT_PATH/01-Raw/$SANITIZED_NAME.url"

# 2. Run pipeline (v2: 3-stage orchestrator)
cd "$(dirname "$0")/.."
VAULT_PATH="$VAULT_PATH" bash scripts/process-inbox.sh
```

## Pipeline Architecture (v2.1.0)

Three-stage pipeline replacing the monolithic v1:

- **Stage 1 — Extract** (shell, no agent): Downloads and extracts content from all URLs/files in parallel. Output: `/tmp/extracted/manifest.json`
- **Stage 2 — Plan** (1 agent, batched): Semantic concept pre-search via qmd + Qwen3-Embedding-0.6B-Q8. Produces per-source creation plans. Output: `/tmp/extracted/plans.json`
- **Stage 3 — Create** (N agents, parallel): Writes Source → Entry → Concept → MoC notes per plan. Handles concept convergence. Configurable parallelism (`--parallel N`).

```bash
# v2 pipeline options
bash scripts/process-inbox.sh                    # Default: 3 parallel agents
bash scripts/process-inbox.sh --parallel 5       # 5 parallel agents
bash scripts/process-inbox.sh --dry-run          # Preview without executing
```

The v1 `process-inbox.sh` is still available as a fallback (single-agent, monolithic).

## Extraction Chain (in code: lib/extract.sh)

- **arxiv** → arxiv HTML (defuddle) → alphaxiv full text → defuddle → liteparse → browser
- **URLs/HTML/X-Twitter** → defuddle (primary) → liteparse (url mode) → browser screenshot
- **YouTube** → TranscriptAPI → Supadata → whisper
- **Podcasts** → download_audio → AssemblyAI → whisper (local fallback)
- **PDFs/Docs** → liteparse (local) → OCR (liteparse --dpi 300) → ocr-and-documents

Unified entry: `source lib/extract.sh && extract_content "$url_or_path"`

## Lock Management

Pipeline uses `acquire_lock()` from `lib/common.sh` to prevent concurrent runs:
- Lock path: `/tmp/obsidian-process-inbox-<vault_hash>.lock`
- Stale detection: PID check + 30-minute timeout
- Manual cleanup: `rmdir /tmp/obsidian-process-inbox-*.lock`

## Note Structures

Check the `template:` frontmatter field. Default is `standard`.

**Template: standard** (default, English):
Summary → Core insights → Other takeaways → Diagrams (optional, n/a if not needed) → Open questions → Linked concepts

**Template: chinese** (for Chinese-language sources):
Frontmatter: `language: zh`, `template: chinese`
摘要 → 核心发现 → 其他要点 → 图表 (optional, n/a if not needed) → 开放问题 → 关联概念

**Template: technical**:
Summary → Key Findings → Data/Evidence → Methodology → Limitations → Linked concepts

**Template: comparison**:
Summary → Side-by-Side Comparison → Pros/Cons → Verdict → Linked concepts

**Template: procedural**:
Summary → Prerequisites → Steps → Gotchas → Linked concepts

**Concepts** (evergreen format, English):
Frontmatter: sources: ["[[source]]"], type: concept, status: review
Core concept → Context (flowing prose — mechanism, significance, evidence, tensions) → Links

**Concepts** (evergreen format, Chinese — language: zh):
核心概念 → 背景 (flowing prose, no sub-headings) → 关联

**MoCs** can be monolingual or bilingual bridges (Chinese/English).

## Naming (in code: `title_to_filename` in lib/common.sh)

**Source filenames MUST be the content's actual title — NOT the platform, author handle, or tweet/post ID.**

- Chinese titles → Chinese filenames (潮汕钱庄与东南亚黑金网络...)
- English titles → kebab-case (the-measles-market-on-kalshi...)
- Papers → actual paper titles (How manipulable are prediction markets...)
- Tweets → first meaningful sentence or topic (Skill Chaining - Why Skills Should Be Actions)
- Blog posts → article title (Ruled by Precession)
- YouTube → video title (Secret History #7 - Death by Meritocracy)
- ❌ NEVER: "Tweet - username - tweetID.md"
- ❌ NEVER: "Blog - domain-slug.md"
- ❌ NEVER: "YouTube - VIDEO_ID.md"
- ❌ NEVER: URL slugs (X-functionspaceHQ-2039554933024776516)

## Critical Rules

1. NEVER touch `07-WIP/`
2. NEVER overwrite existing notes
3. YAML wikilinks quoted: `source: "[[note]]"`
4. [[wikilinks]] for internal links
5. Chinese body stays Chinese, English YAML/tags
6. NO stubs — every section must have real content at creation
7. Tags must be topic-specific English (never platform names like x.com, tweet)
8. Concepts use evergreen format — flowing prose in Context/背景, no sub-headings
9. Sources for concepts go in frontmatter, not body
10. Concept convergence: search existing concepts before creating new ones

## Post-Change Sync

After updating codebase (prompts, templates, scripts, lib), ALWAYS:
1. Copy updated files to vault Meta/ directories:
   - `cp scripts/*.sh $VAULT_PATH/Meta/Scripts/`
   - `cp lib/*.sh $VAULT_PATH/Meta/Scripts/../lib/`
   - `cp prompts/*.prompt $VAULT_PATH/Meta/Scripts/../prompts/`
   - `cp templates/*.md $VAULT_PATH/Meta/Templates/`
2. Update existing vault content to match new structures (bulk migration scripts)
3. Rebuild wiki-index.md
4. Sync: `npx obsidian-headless sync --path $VAULT_PATH`

Updating codebase alone is NOT complete — vault content must match.

## Troubleshooting

- Lock file: `rmdir /tmp/obsidian-process-inbox-*.lock` (or `rm -rf` for legacy `obsidian-process-inbox-*.lock`)
- Defuddle not found: `npm install -g defuddle`
- Liteparse not found: check PATH or install liteparse
- Medium/blocked sites: defuddle → liteparse → browser screenshot (automatic fallback)
- qmd/concept search: run `scripts/setup-qmd.sh` to initialize concept index
- SCRIPT_DIR bug: extract.sh uses `_EXTRACT_DIR`, not inherited `SCRIPT_DIR`
- Sync: `npx obsidian-headless sync --path /home/linuxuser/MyVault`
