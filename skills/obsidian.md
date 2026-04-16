---
name: obsidian
description: "Process any URL, file, or link into the Obsidian vault. Drop URLs in chat, pipeline handles extraction + wiki creation."
version: 2.4.0
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
- **URLs** → defuddle → liteparse → tavily → browser
- **YouTube** → TranscriptAPI → Supadata → whisper
- **Podcasts** → AssemblyAI → whisper
- **PDFs** → liteparse → OCR

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
6. MoC headings: `English / 中文` format
7. Cross-language concept convergence → bilingual note (template: bilingual, languages: [en, zh])

## Troubleshooting

- Lock file: `rm /tmp/obsidian-process-inbox-*.lock`
- Defuddle not found: `npm install -g defuddle`
- Medium blocked: fallback to tavily extract
- SCRIPT_DIR bug: extract.sh uses `_EXTRACT_DIR`, not inherited `SCRIPT_DIR`
