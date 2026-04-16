---
name: obsidian
description: "Process any URL, file, or link into the Obsidian vault. Drop URLs in chat, pipeline handles extraction + wiki creation."
version: 2.0.1
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

# 2. Run pipeline (handles extraction, Entry, Concept, MoC, edges, wiki-index)
cd /home/linuxuser/workspaces/gamma/obsidian-automation
VAULT_PATH="$VAULT_PATH" bash scripts/process-inbox.sh
```

## Extraction Chain (in code)

- **arxiv** → `arxiv.org/html/IDv1` (defuddle) → alphaxiv → defuddle abstract
- **URLs** → defuddle → liteparse → browser screenshot
- **X/Twitter** → defuddle (primary, works well) → liteparse → browser
- **YouTube** → TranscriptAPI → Supadata → whisper
- **Podcasts** → AssemblyAI → whisper
- **PDFs** → liteparse → OCR

## Note Structures

**Entries** (template: chinese):
摘要 → 核心发现 → 其他要点 → 图表 (optional, n/a if not needed) → 开放问题 → 关联概念

**Entries** (template: standard):
Summary → Core insights → Other takeaways → Diagrams (optional, n/a if not needed) → Open questions → Linked concepts

**Concepts** (evergreen format, language: zh):
Frontmatter: sources: ["[[source]]"]
核心概念 → 背景 (flowing prose — mechanism, significance, evidence, tensions) → 关联

**Concepts** (evergreen format, English):
Frontmatter: sources: ["[[source]]"]
Core concept → Context (flowing prose) → Links

## Naming (in code: `title_to_filename`)

- Chinese titles → Chinese filenames (潮汕钱庄与东南亚黑金网络...)
- English titles → kebab-case (the-measles-market-on-kalshi...)
- Papers → actual paper titles (How manipulable are prediction markets...)
- Never URL slugs (❌ X-functionspaceHQ-2039554933024776516)

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

- Lock file: `rm /tmp/obsidian-process-inbox-*.lock`
- Defuddle not found: `npm install -g defuddle`
- Medium blocked: fallback to tavily extract
- SCRIPT_DIR bug: extract.sh uses `_EXTRACT_DIR`, not inherited `SCRIPT_DIR`
- Sync: `npx obsidian-headless sync --path /home/linuxuser/MyVault`
