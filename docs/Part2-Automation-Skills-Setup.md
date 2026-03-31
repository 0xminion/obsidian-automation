# Obsidian AI-Automated PKM Vault — Part 2: Automation & Skills Setup

> **Prerequisite:** Your vault folder structure from Part 1 must already exist. If not, complete Part 1 first.

---

## Phase 1: Install Prerequisites

### 1.1 Node.js (v18+)

Required for Defuddle, LiteParse, TranscriptAPI, and most agent runtimes. Install from [nodejs.org](https://nodejs.org).

### 1.2 Defuddle CLI — primary content extractor

Defuddle is the primary tool for converting web content and applicable files to markdown. It strips ads, navigation, and clutter, returning clean structured content.

```bash
npm install -g defuddle
```

### 1.3 LiteParse — fallback parser

LiteParse is used as a fallback when Defuddle can't handle a file (complex PDFs, scanned documents, office formats). It runs locally with built-in OCR via Tesseract.js.

```bash
npm install -g @llamaindex/liteparse
```

Or on macOS:

```bash
brew tap run-llama/liteparse
brew install llamaindex-liteparse
```

For office document conversion (`.docx`, `.pptx`, `.xlsx`), install LibreOffice:

```bash
# macOS
brew install --cask libreoffice

# Ubuntu/Debian
sudo apt-get install libreoffice
```

### 1.4 Transcript providers — for YouTube links

YouTube links use two transcript providers with automatic fallback:

**Primary — TranscriptAPI:** Sign up at [transcriptapi.com](https://transcriptapi.com) (100 free credits, no credit card required).

**Fallback — Supadata:** Sign up at [supadata.ai](https://supadata.ai) and get your API key from the [dashboard](https://dash.supadata.ai). Used when TranscriptAPI returns 402/404/error or `TRANSCRIPT_API_KEY` is empty.

Set both as environment variables:

```bash
export TRANSCRIPT_API_KEY="your-transcriptapi-key"
export SUPADATA_API_KEY="your-supadata-key"
```

Add these to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.) so they persist.

**API details:**

| Provider | Endpoint | Auth header | Response |
|---|---|---|---|
| TranscriptAPI | `GET https://transcriptapi.com/api/v2/youtube/transcript` | `Authorization: Bearer $KEY` | Text transcript + metadata (title, author) |
| Supadata | `GET https://api.supadata.ai/v1/youtube/transcript` | `x-api-key: $KEY` | JSON with `content` (text), `lang`, `availableLangs` |

Supadata returns HTTP 202 for videos over 20 minutes (async processing). Poll the returned `jobId` at `/v1/youtube/transcript/{jobId}` every few seconds. Supadata does not return video metadata (title, channel) — the agent extracts this from the YouTube page.

### 1.5 Humanizer skill

Removes AI-sounding patterns from generated text. All AI-generated prose in `02-Distilled/`, `03-Atomic/`, and `04-MoCs/` must pass through Humanizer before being written.

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/blader/humanizer.git ~/.claude/skills/humanizer
```

Adjust the path for your agent (Hermes: `~/.hermes/skills/`, Codex: `~/.codex/skills/`).

### 1.6 Choose and install your AI agent

This guide is agent-agnostic. Pick one:

**Claude Code** (Anthropic) — default in `process-inbox.sh`:
```bash
npm install -g @anthropic-ai/claude-code
export ANTHROPIC_API_KEY="sk-ant-..."
```

**Hermes Agent** (Nous Research):
```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

**Codex CLI** (OpenAI):
```bash
npm install -g @openai/codex
```

Or any [agentskills.io](https://agentskills.io)-compatible agent.

Set `AGENT_CMD` when running the script:

| Agent | AGENT_CMD |
|---|---|
| Claude Code | `claude -p` (default) |
| Hermes Agent | `hermes run --prompt` |
| Codex CLI | `codex exec` |

---

## Phase 2: Install Agent Skills

### 2.1 Obsidian skills (kepano)

```bash
# Claude Code (into vault root)
cd /path/to/MyVault
git clone https://github.com/kepano/obsidian-skills.git .claude/obsidian-skills

# Or via npx (any agent)
npx skills add git@github.com:kepano/obsidian-skills.git
```

This installs: `obsidian-markdown`, `obsidian-cli`, `obsidian-bases`, `json-canvas`, `defuddle`.

### 2.2 YouTube transcript skill (TranscriptAPI via ClawHub)

```bash
# Via npx skills
npx skills add ZeroPointRepo/youtube-skills --skill youtube-full

# Or manual clone
git clone https://github.com/ZeroPointRepo/youtube-skills.git
cp -r youtube-skills/skills/youtube-full ~/.claude/skills/
```

This skill uses the TranscriptAPI REST endpoint to fetch transcripts:

```bash
# Primary — TranscriptAPI
curl -s "https://transcriptapi.com/api/v2/youtube/transcript?video_url=VIDEO_URL&format=text&include_timestamp=true&send_metadata=true" \
  -H "Authorization: Bearer $TRANSCRIPT_API_KEY"

# Fallback — Supadata (used automatically when TranscriptAPI fails)
curl -s "https://api.supadata.ai/v1/youtube/transcript?url=VIDEO_URL&text=true&lang=en" \
  -H "x-api-key: $SUPADATA_API_KEY"
```

### 2.3 Humanizer skill

Already installed in Phase 1.5. Verify `SKILL.md` exists at your agent's skills path.

### 2.4 LiteParse agent skill (optional)

```bash
npx skills add run-llama/llamaparse-agent-skills/liteparse
```

### 2.5 Verify all skills

Your agent's skills directory should now contain:

```
skills/
├── obsidian-skills/       # obsidian-markdown, obsidian-cli, obsidian-bases, json-canvas, defuddle
├── youtube-full/          # TranscriptAPI YouTube transcripts
├── humanizer/             # AI writing pattern removal
└── liteparse/             # (optional) PDF/doc parsing agent skill
```

---

## Phase 3: Create Note Templates

Create these files in `Meta/Templates/`.

**YAML note:** Wikilinks (`[[note-name]]`) in YAML frontmatter MUST always be quoted because YAML interprets `[[` as a nested list. Use `source: "[[note-name]]"` not `source: [[note-name]]`.

### `Meta/Templates/Source.md`

```markdown
---
title: "{{title}}"
source_url: "{{url}}"
source_type: "{{type}}"
author: "{{author}}"
date_captured: {{date}}
date_published:
tags:
  - source
  - source/{{type}}
status: processed
aliases: []
---

# {{title}}

> [!info] Source metadata
> **Author:** {{author}}
> **URL:** [Link]({{url}})
> **Type:** {{type}}
> **Captured:** {{date}}

## Original content

{{content}}
```

### `Meta/Templates/Distilled.md`

Every Distilled note must follow this exact structure — no exceptions.

```markdown
---
title: "{{title}}"
source: "[[{{source_note}}]]"
date_distilled: {{date}}
tags:
  - distilled
  - {{tag1 through tag5-10}}
status: review
aliases: []
---

# {{title}}

## Summary

{{3-5 sentence summary of what this source is about}}

## ELI5 insights

### Core insights

{{The main, most important findings. Extract as many as the content
warrants — not top 5, not top 10, but everything significant.
Each bullet should be explained in plain, simple language that
a non-expert could understand.}}

### Other takeaways

{{Other findings deemed important but not core. Again, extract
as many as the content warrants. No artificial limits.
Same ELI5 treatment.}}

## Diagrams

{{Mermaid diagrams, mindmaps, or flowcharts if the content involves
processes, relationships, hierarchies, or concepts that benefit
from visual explanation. If nothing warrants a diagram: "N/A"}}

## Open questions

{{Questions, issues, or gaps worth thinking about further.
What doesn't the source answer? What assumptions does it make?}}

## Linked concepts

{{Wikilinks to related Atomic notes, other Distilled notes, and MoCs}}
```

### `Meta/Templates/Atomic.md`

```markdown
---
title: "{{title}}"
date_created: {{date}}
source: "[[{{source_note}}]]"
tags:
  - atomic
  - {{tag1 through tag2-5}}
status: evergreen
aliases: []
---

# {{title}}

{{content — one clear idea, 2-5 sentences, no padding}}

---

## References

- Source: "[[{{source_note}}]]"
- Related: {{related_links}}
```

### `Meta/Templates/MoC.md`

```markdown
---
title: "{{title}}"
date_created: {{date}}
date_updated: {{date}}
tags:
  - moc
  - {{topic_tag}}
type: moc
aliases: []
---

# {{title}}

> [!note] Map of content
> This note serves as a hub for everything related to **{{topic}}**.

## Core concepts

{{atomic_links}}

## Source material

{{source_links}}

## Distilled notes

{{distilled_links}}

## Open questions

-

## Related maps

{{related_mocs}}
```

---

## Phase 4: The AI Processing Script

This is the core automation. It monitors `00-Inbox/raw/` and `00-Inbox/clippings/`, routes each item through the correct parser with retry logic, generates notes, humanizes them, and writes them to the vault.

The canonical script lives at `scripts/process-inbox.sh` in this repository. Copy it to your vault:

```bash
chmod +x scripts/process-inbox.sh
cp scripts/process-inbox.sh ~/MyVault/Meta/Scripts/
```

### Key features

- **Agent-agnostic** — defaults to `claude -p`, configurable via `AGENT_CMD` env var
- **Retry logic** — `run_with_retry` wraps every processing call with exponential backoff (3 attempts, 5s/10s delays). On failure, the agent receives instructions to try alternative approaches. Files that fail all retries are moved to `00-Inbox/failed/`
- **Vault-specific lock file** — prevents overlapping runs per vault while allowing parallel execution across different vaults
- **Auto-creates `Meta/Scripts/`** — ensures the log directory exists before first write
- **Parser routing:**
  - URLs: Defuddle primary, LiteParse fallback
  - YouTube: TranscriptAPI primary, Supadata fallback
  - PDFs/DOCX/PPTX: Defuddle primary, LiteParse fallback
  - Clippings: direct passthrough (already markdown)
- **YAML correctness** — all prompts instruct the agent to quote wikilinks in frontmatter (`source: "[[note]]"`) since YAML interprets `[[` as a nested list
- **Tag consolidation** — agents run `obsidian tags sort=count counts` before creating tags to prevent sprawl
- **Humanization** — all prose in `02-Distilled/`, `03-Atomic/`, `04-MoCs/` is humanized before writing

### Configuration

| Variable | Default | Description |
|---|---|---|
| `VAULT_PATH` | `$HOME/MyVault` | Absolute path to vault root |
| `AGENT_CMD` | `claude -p` | Agent command to execute prompts |
| `TRANSCRIPT_API_KEY` | (env) | TranscriptAPI key for YouTube transcripts |
| `SUPADATA_API_KEY` | (env) | Supadata key for YouTube transcript fallback |
| `MAX_RETRIES` | `3` | Number of retry attempts per file |

---

## Phase 5: Set Up the Cron Job

### Linux / macOS cron

```bash
crontab -e
```

```bash
# Every 30 minutes
*/30 * * * * VAULT_PATH="$HOME/MyVault" AGENT_CMD="claude -p" ANTHROPIC_API_KEY="sk-ant-..." TRANSCRIPT_API_KEY="your-key" SUPADATA_API_KEY="your-key" $HOME/MyVault/Meta/Scripts/process-inbox.sh

# Every hour
0 * * * * VAULT_PATH="$HOME/MyVault" AGENT_CMD="claude -p" ANTHROPIC_API_KEY="sk-ant-..." TRANSCRIPT_API_KEY="your-key" SUPADATA_API_KEY="your-key" $HOME/MyVault/Meta/Scripts/process-inbox.sh

# Twice daily (9am and 6pm)
0 9,18 * * * VAULT_PATH="$HOME/MyVault" AGENT_CMD="claude -p" ANTHROPIC_API_KEY="sk-ant-..." TRANSCRIPT_API_KEY="your-key" SUPADATA_API_KEY="your-key" $HOME/MyVault/Meta/Scripts/process-inbox.sh
```

### macOS launchd (alternative)

Create `~/Library/LaunchAgents/com.obsidian.inbox-processor.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.obsidian.inbox-processor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/YOU/MyVault/Meta/Scripts/process-inbox.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>VAULT_PATH</key>
        <string>/Users/YOU/MyVault</string>
        <key>AGENT_CMD</key>
        <string>claude -p</string>
        <key>ANTHROPIC_API_KEY</key>
        <string>sk-ant-...</string>
        <key>TRANSCRIPT_API_KEY</key>
        <string>your-key</string>
        <key>SUPADATA_API_KEY</key>
        <string>your-key</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
    <key>StartInterval</key>
    <integer>1800</integer>
    <key>StandardOutPath</key>
    <string>/tmp/obsidian-processor.out</string>
    <key>StandardErrorPath</key>
    <string>/tmp/obsidian-processor.err</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.obsidian.inbox-processor.plist
```

### Hermes Agent built-in cron (alternative)

```bash
hermes schedule add \
  --name "inbox-processor" \
  --interval "30m" \
  --command "Process all files in 00-Inbox/raw/ and 00-Inbox/clippings/" \
  --workdir "$HOME/MyVault"
```

---

## Phase 6: Install Obsidian Plugins

Install via Settings → Community plugins → Browse:

| Plugin | Purpose |
|---|---|
| **Dataview** | Query vault content as live tables — powers the Dashboard |
| **Templater** | Advanced templating when creating notes manually |
| **Tag Wrangler** | Bulk rename/merge tags to prevent AI-created tag sprawl |
| **Obsidian Web Clipper** | Clip web pages to `00-Inbox/clippings/` |
| **Auto Link Title** | Fetches page titles when you paste URLs |
| **Periodic Notes** | Daily/weekly notes for journaling |

**Configure Web Clipper** to save to `00-Inbox/clippings/` with this frontmatter:

```markdown
---
source_url: "{{url}}"
title: "{{title}}"
date_captured: {{date}}
status: unprocessed
tags:
  - inbox
---
```

---

## Phase 7: Build the Dashboard

Create `Meta/Dashboard.md`:

````markdown
---
title: Vault dashboard
tags:
  - meta
  - dashboard
---

# Vault dashboard

## Inbox — waiting to be processed

```dataview
TABLE file.name AS "File", file.ctime AS "Added"
FROM "00-Inbox/raw" OR "00-Inbox/clippings"
SORT file.ctime DESC
```

## Failed items (needs manual review)

```dataview
TABLE file.name AS "File", file.ctime AS "Added"
FROM "00-Inbox/failed"
SORT file.ctime DESC
```

## Quick notes (never auto-processed)

```dataview
TABLE file.name AS "Note", file.mtime AS "Modified"
FROM "00-Inbox/quick notes"
SORT file.mtime DESC
```

## Recently distilled

```dataview
TABLE source AS "From", date_distilled AS "Distilled", length(file.tags) AS "Tags"
FROM "02-Distilled"
SORT date_distilled DESC
LIMIT 20
```

## Recent atomic notes

```dataview
TABLE source AS "Source", date_created AS "Created"
FROM "03-Atomic"
SORT date_created DESC
LIMIT 20
```

## Maps of content

```dataview
TABLE date_updated AS "Last updated", length(file.inlinks) AS "Inlinks"
FROM "04-MoCs"
SORT date_updated DESC
```

## Work in progress

```dataview
TABLE status AS "Status", file.mtime AS "Modified"
FROM "05-WIP"
SORT file.mtime DESC
```

## Tag frequency (top 30)

```dataview
TABLE length(rows) AS "Count"
FROM "03-Atomic" OR "02-Distilled"
FLATTEN file.tags AS tag
WHERE !contains(tag, "atomic") AND !contains(tag, "distilled")
GROUP BY tag
SORT length(rows) DESC
LIMIT 30
```
````

---

## Phase 8: Test the Pipeline

### Test 1 — URL (Defuddle)

Create `00-Inbox/raw/test-url.md`:
```
https://en.wikipedia.org/wiki/Zettelkasten
```

Run: `VAULT_PATH="$HOME/MyVault" bash "$HOME/MyVault/Meta/Scripts/process-inbox.sh"`

**Verify:**
- [ ] Source note in `01-Sources/` with full content
- [ ] Distilled note in `02-Distilled/` follows exact structure: Summary → ELI5 Core insights → Other takeaways → Diagrams → Open questions → Linked concepts
- [ ] Distilled has 5-10 topic tags (reusing existing where possible)
- [ ] Wikilinks in YAML frontmatter are quoted (e.g., `source: "[[note]]"`)
- [ ] Prose reads natural (no AI patterns)
- [ ] Atomic notes in `03-Atomic/` with 2-5 tags each
- [ ] MoCs updated or created in `04-MoCs/`
- [ ] Original file archived to `06-Archive/processed-inbox/`

### Test 2 — YouTube link (TranscriptAPI → Supadata fallback)

Create `00-Inbox/raw/test-yt.md`:
```
https://www.youtube.com/watch?v=dQw4w9WgXcQ
```

**Verify:**
- [ ] Transcript was fetched (TranscriptAPI primary, Supadata fallback)
- [ ] Source note contains full transcript
- [ ] Full pipeline completed (Distilled → Atomic → MoC)

### Test 3 — PDF (Defuddle → LiteParse fallback)

Drop a PDF into `00-Inbox/raw/`. Run the processor.

**Verify:**
- [ ] PDF copied to `01-Sources/` and embedded in Source note
- [ ] Full pipeline completed
- [ ] Original archived to `06-Archive/processed-inbox/`

### Test 4 — Quick notes untouched

Create `00-Inbox/quick notes/my-thought.md`. Run the processor. **Verify the file is completely untouched.**

### Test 5 — Retry logic

Temporarily set an invalid API key. Run the processor. Check `Meta/Scripts/processing.log` for:
- Three retry attempts with increasing delays (5s, 10s)
- Failed file moved to `00-Inbox/failed/`

### Test 6 — Cron execution

Wait for the next scheduled run. Check `Meta/Scripts/processing.log`.

---

## Phase 9: Ongoing Maintenance

### Daily workflow

1. Drop links, PDFs, YouTube URLs into `00-Inbox/raw/`
2. Use `00-Inbox/quick notes/` for your own thinking (safe from automation)
3. Cron picks up `raw/` and `clippings/` automatically
4. Check Dashboard; review Distilled and Atomic notes
5. Check `00-Inbox/failed/` for items that need manual attention

### Weekly review

Launch your agent interactively and ask it to:

- Find orphan notes and suggest connections
- Review MoCs for splitting or merging
- Find atomic notes that should be cross-linked
- Run `obsidian tags sort=count counts` and flag near-duplicate tags
- Generate a weekly summary of vault additions

### Tag hygiene

The automation searches existing tags before creating new ones, but slight variations still happen. Use Tag Wrangler weekly to merge duplicates (e.g., `#topic/ml` and `#topic/machine-learning`).

---

## Tool Routing Summary

| Input type | Primary parser | Fallback |
|---|---|---|
| URLs (articles, blogs, docs) | **Defuddle** (`defuddle parse <url> --md`) | **LiteParse** (`lit parse`) |
| YouTube links | **TranscriptAPI** (youtube-full skill) | **Supadata** (`api.supadata.ai`) |
| PDFs | **Defuddle** (if applicable) | **LiteParse** (`lit parse file.pdf`) |
| Office docs (.docx, .pptx) | **Defuddle** (if applicable) | **LiteParse** (auto-converts via LibreOffice) |
| Web clipper saves | Direct passthrough (already markdown) | — |

| Output folder | Humanized? | Tag requirements |
|---|---|---|
| `01-Sources/` | No (original content) | Standard source tags |
| `02-Distilled/` | **Yes** | Min 5, max 10 topic tags |
| `03-Atomic/` | **Yes** | Min 2, max 5 topic tags |
| `04-MoCs/` | **Yes** | Topic tag |
| `06-Archive/` | No (just moves) | — |

---

## Retry Logic Summary

The `run_with_retry` function wraps every processing call:

| Attempt | Delay before retry | Behavior |
|---|---|---|
| 1 | — | Normal execution |
| 2 | 5 seconds | Retries with instructions to try alternative approaches |
| 3 | 10 seconds | Final attempt with even stronger fallback instructions |
| After 3 | — | Gives up, moves file to `00-Inbox/failed/` for manual review |

Alternative approaches the agent is instructed to try on retry:
- Swap Defuddle for LiteParse (or vice versa)
- Try different LiteParse flags (`--no-ocr`, `--target-pages`)
- Use bare video ID instead of full YouTube URL
- Try Supadata if TranscriptAPI failed
- Create target directories if missing
- Simplify the prompt if rate-limited
- Write to a temp location and move

---

## Troubleshooting

**"obsidian: command not found"** — Obsidian must be open. Enable CLI in Settings → General.

**"lit: command not found"** — `npm install -g @llamaindex/liteparse` and check your PATH.

**"defuddle: command not found"** — `npm install -g defuddle` and check your PATH.

**TranscriptAPI returns 401** — Check `TRANSCRIPT_API_KEY` is set correctly in your cron environment. Free tier gives 100 credits; check your dashboard at transcriptapi.com.

**TranscriptAPI returns 402/404** — Falls back to Supadata automatically. If both fail, check `SUPADATA_API_KEY` is set. Get your key at [dash.supadata.ai](https://dash.supadata.ai).

**Files stuck in `00-Inbox/failed/`** — These failed all 3 retry attempts. Check `Meta/Scripts/processing.log` for the specific errors, then process manually or fix the issue and move them back to `raw/`.

**Tag sprawl** — Run `obsidian tags sort=count counts` to see the full tag list. The automation searches existing tags before creating new ones, but review weekly with Tag Wrangler.

**Humanizer not activating** — Verify `SKILL.md` exists in your agent's skills directory. The agent must be able to discover it at runtime.

**Quick notes getting processed** — The main loop explicitly only iterates `00-Inbox/raw/*` and `00-Inbox/clippings/*.md`. If quick notes are touched, something else is invoking the agent with different instructions.

**Wikilinks breaking YAML** — Ensure all wikilinks in frontmatter are quoted: `source: "[[note-name]]"`. Unquoted `[[` is interpreted by YAML as a nested list.
