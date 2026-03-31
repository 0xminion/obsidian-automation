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

### 1.4 TranscriptAPI setup — for YouTube links

YouTube links use the TranscriptAPI skill from ClawHub. You need a free API key (100 credits on signup, no credit card required).

Sign up at [transcriptapi.com](https://transcriptapi.com) and get your API key. Then set it as an environment variable:

```bash
export TRANSCRIPT_API_KEY="your-key-here"
```

Add this to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.) so it persists.

### 1.5 Humanizer skill

Removes AI-sounding patterns from generated text. All AI-generated prose in `02-Distilled/`, `03-Atomic/`, and `04-MoCs/` must pass through Humanizer before being written.

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/blader/humanizer.git ~/.claude/skills/humanizer
```

Adjust the path for your agent (Hermes: `~/.hermes/skills/`, Codex: `~/.codex/skills/`).

### 1.6 Choose and install your AI agent

This guide is agent-agnostic. Pick one:

**Claude Code** (Anthropic):
```bash
npm install -g @anthropic-ai/claude-code
export ANTHROPIC_API_KEY="sk-ant-..."
```

**Hermes Agent** (Nous Research):
```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

**Codex CLI** (OpenAI) or any [agentskills.io](https://agentskills.io)-compatible agent.

Throughout this guide, `<agent>` is a placeholder. Replace with your actual command (e.g., `claude -p`, `hermes run --prompt`).

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

This skill uses the TranscriptAPI REST endpoint to fetch transcripts. The API call is:

```bash
curl -s "https://transcriptapi.com/api/v2/youtube/transcript?video_url=VIDEO_URL&format=text&include_timestamp=true&send_metadata=true" \
  -H "Authorization: Bearer $TRANSCRIPT_API_KEY"
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

- Source: [[{{source_note}}]]
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

## Phase 4: Write the AI Processing Script

This is the core automation. It monitors `00-Inbox/raw/` and `00-Inbox/clippings/`, routes each item through the correct parser with retry logic, generates notes, humanizes them, and writes them to the vault.

### `Meta/Scripts/process-inbox.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════
VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
LOG_FILE="$VAULT_PATH/Meta/Scripts/processing.log"
LOCK_FILE="/tmp/obsidian-inbox-processor.lock"
MAX_RETRIES=3

# Agent command — change for your agent
# Claude Code:   AGENT_CMD="claude -p"
# Hermes Agent:  AGENT_CMD="hermes run --prompt"
# Codex CLI:     AGENT_CMD="codex exec"
AGENT_CMD="${AGENT_CMD:-claude -p}"

# ═══════════════════════════════════════════════════════════
# SAFETY: prevent overlapping runs
# ═══════════════════════════════════════════════════════════
if [ -f "$LOCK_FILE" ]; then
  echo "$(date): Another instance running. Exiting." >> "$LOG_FILE"
  exit 0
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

log() { echo "$(date): $1" >> "$LOG_FILE"; }

# ═══════════════════════════════════════════════════════════
# RETRY LOGIC — exponential backoff, max 3 attempts
# On failure, instructs the agent to try alternative approaches
# ═══════════════════════════════════════════════════════════
run_with_retry() {
  local description="$1"
  local prompt="$2"
  local attempt=1
  local delay=5  # initial delay in seconds

  while [ $attempt -le $MAX_RETRIES ]; do
    log "Attempt $attempt/$MAX_RETRIES: $description"

    if cd "$VAULT_PATH" && $AGENT_CMD "$prompt" 2>> "$LOG_FILE"; then
      log "SUCCESS: $description"
      return 0
    fi

    local exit_code=$?
    log "FAILED (exit $exit_code): $description — attempt $attempt/$MAX_RETRIES"

    if [ $attempt -lt $MAX_RETRIES ]; then
      log "Waiting ${delay}s before retry (exponential backoff)..."
      sleep $delay
      delay=$((delay * 2))

      # Augment the prompt with retry instructions
      prompt="$prompt

RETRY CONTEXT: This is attempt $((attempt + 1)) of $MAX_RETRIES.
The previous attempt failed. Try alternative approaches:
- If a URL failed with Defuddle, fall back to LiteParse or direct fetch.
- If PDF parsing failed, try with --no-ocr flag or different page ranges.
- If the TranscriptAPI call failed, try with a bare video ID instead of full URL.
- If a file operation failed, check if the target directory exists and create it.
- If an API call was rate-limited, use a simpler/shorter prompt.
- If note creation failed, verify the file path and try writing to a temp location first.
Be resourceful. Find a way to complete the task."
    fi

    attempt=$((attempt + 1))
  done

  log "GIVING UP after $MAX_RETRIES attempts: $description"
  # Move the failed file to a failed/ subfolder for manual review
  local file_arg
  file_arg=$(echo "$description" | grep -oP '(?<=file: ).*' || true)
  if [ -n "$file_arg" ] && [ -f "$file_arg" ]; then
    mkdir -p "$VAULT_PATH/00-Inbox/failed"
    mv "$file_arg" "$VAULT_PATH/00-Inbox/failed/" 2>/dev/null || true
    log "Moved failed file to 00-Inbox/failed/"
  fi
  return 1
}

# ═══════════════════════════════════════════════════════════
# FILE TYPE DETECTION
# ═══════════════════════════════════════════════════════════
is_url_file() {
  local file="$1"
  local ext="${file##*.}"
  if [[ "$ext" == "url" ]]; then return 0; fi
  if [[ "$ext" == "md" || "$ext" == "txt" ]]; then
    local content
    content=$(cat "$file" | tr -d '[:space:]')
    if [[ "$content" =~ ^https?:// ]]; then return 0; fi
  fi
  return 1
}

is_pdf_file() {
  [[ "${1##*.}" =~ ^[Pp][Dd][Ff]$ ]]
}

is_youtube_link() {
  local content
  content=$(cat "$1" 2>/dev/null | tr -d '[:space:]')
  [[ "$content" =~ (youtube\.com|youtu\.be) ]]
}

# ═══════════════════════════════════════════════════════════
# SHARED PROMPT INSTRUCTIONS
# ═══════════════════════════════════════════════════════════
COMMON_INSTRUCTIONS="
VAULT LOCATION: $VAULT_PATH
AGENT SKILLS AVAILABLE: obsidian-markdown, obsidian-cli, defuddle, humanizer,
  youtube-full (TranscriptAPI), liteparse

CRITICAL RULES:
1. NEVER touch anything in '00-Inbox/quick notes/'. Off-limits.
2. ALL AI-generated prose for 02-Distilled/, 03-Atomic/, or 04-MoCs/
   MUST be run through the Humanizer skill before writing to disk.
   Draft the content → humanize it → write the final file.
3. Use [[wikilinks]] for all internal vault links.
4. Use Obsidian-flavored markdown (callouts, frontmatter, tags).
5. Use obsidian CLI where helpful:
   obsidian create, obsidian search, obsidian append, obsidian property:set

PARSER ROUTING:
- Primary: Use Defuddle for any URLs and applicable file-to-markdown conversions.
- Fallback: If Defuddle fails or can't handle the format, fall back to LiteParse:
    lit parse <file> --format text
- YouTube links: Use TranscriptAPI (youtube-full skill) exclusively.
  API call: curl -s 'https://transcriptapi.com/api/v2/youtube/transcript?video_url=VIDEO_URL&format=text&include_timestamp=true&send_metadata=true'
    -H 'Authorization: Bearer \$TRANSCRIPT_API_KEY'
  Then convert the transcript to clean markdown.

TAG CONSOLIDATION:
Before creating new tags, ALWAYS search existing tags in the vault first:
  obsidian tags sort=count counts
Reuse existing tags wherever possible. Only create a new tag if no existing
tag covers the concept. This prevents tag sprawl and keeps the taxonomy clean.

RETRY BEHAVIOR:
If any step fails (API call, file operation, parsing), try an alternative
approach before giving up. Be resourceful.
"

# ═══════════════════════════════════════════════════════════
# DISTILLED NOTE STRUCTURE (strict)
# ═══════════════════════════════════════════════════════════
DISTILLED_STRUCTURE="
DISTILLED NOTE STRUCTURE — follow EXACTLY for every note in 02-Distilled/:

Frontmatter must include:
  - title, source (wikilink), date_distilled, status: review
  - tags: minimum 5, maximum 10 topic-specific tags (not counting 'distilled')
  - BEFORE choosing tags: run 'obsidian tags sort=count counts' and reuse
    existing tags wherever a match exists. Only mint a new tag if nothing fits.

Body sections IN THIS ORDER:

## Summary
3-5 sentence summary of what the source is about. Plain language, no fluff.

## ELI5 insights

### Core insights
The main, most important findings. Explain each one as if to a smart
12-year-old — simple language, no jargon, concrete examples where possible.
Extract EVERYTHING significant. Not top 5, not top 10 — as many as exist.
Each bullet should be a substantive point with a clear ELI5 explanation.

### Other takeaways
Other findings that are deemed important but not core. Same ELI5 treatment.
Again, extract as many as the content warrants. No artificial limits.

## Diagrams
If the content involves processes, relationships, hierarchies, comparisons,
or any concept that would be clearer as a visual: include a Mermaid diagram,
mindmap, or flowchart using Obsidian's native mermaid code block support.
If no diagram would genuinely help, write 'N/A — content is straightforward.'

## Open questions
Questions, issues, or gaps raised by this content that are worth thinking
about further. What doesn't the source answer? What assumptions does it make?

## Linked concepts
Wikilinks to related Atomic notes, other Distilled notes, and MoCs.
Use 'obsidian search' to find existing related notes in the vault.
"

# ═══════════════════════════════════════════════════════════
# ATOMIC NOTE RULES
# ═══════════════════════════════════════════════════════════
ATOMIC_RULES="
ATOMIC NOTE RULES for 03-Atomic/:
- One clear, standalone idea per note.
- Title = the idea expressed as a concise phrase.
- Body = 2-5 sentences explaining the idea. No padding.
- Frontmatter tags: minimum 2, maximum 5 topic-specific tags
  (not counting 'atomic').
- BEFORE choosing tags: run 'obsidian tags sort=count counts' and reuse
  existing tags. Only create new tags if nothing fits.
- Always include a wikilink back to the Source and Distilled notes.
- Search the vault for related Atomic notes and add wikilinks.
- ALL prose must be humanized before writing.
"

# ═══════════════════════════════════════════════════════════
# PROCESS: YouTube links (TranscriptAPI → markdown)
# ═══════════════════════════════════════════════════════════
process_youtube() {
  local file="$1"
  local url
  url=$(cat "$file" | tr -d '[:space:]')

  run_with_retry "YouTube — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a YouTube video link.
FILE: '$file'
URL: $url

STEP 1 — FETCH TRANSCRIPT
Use the TranscriptAPI skill (youtube-full) to get the transcript:
  curl -s 'https://transcriptapi.com/api/v2/youtube/transcript?video_url=$url&format=text&include_timestamp=true&send_metadata=true' \\
    -H 'Authorization: Bearer \$TRANSCRIPT_API_KEY'
Extract the transcript text and metadata (title, author).
Convert the transcript into clean, readable markdown paragraphs.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '01-Sources/' with:
  - The YouTube URL, video title, channel name
  - The full transcript as markdown in the 'Original content' section
  - Frontmatter: title, source_url, source_type: youtube, author (channel), tags, status: processed

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft the full Distilled note from the transcript content.
Humanize all prose, then write to '02-Distilled/'.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Extract standalone ideas from the video content.
Draft each, humanize, then write to '03-Atomic/'.

STEP 5 — UPDATE MoCs
Search existing MoCs: obsidian search query=\"<topic>\"
Update relevant MoCs or create new ones if warranted. Humanize MoC prose.

STEP 6 — ARCHIVE
Move original inbox file to '06-Archive/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: URLs (Defuddle primary → LiteParse fallback)
# ═══════════════════════════════════════════════════════════
process_url() {
  local file="$1"

  run_with_retry "URL — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a URL from the inbox.
FILE: '$file'

STEP 1 — EXTRACT CONTENT
Read the file to get the URL. Use Defuddle CLI as the PRIMARY extractor:
  defuddle parse <the_url> --md
If Defuddle fails or returns empty/unusable content, FALL BACK to LiteParse:
  Download the page, then: lit parse <downloaded_file> --format text
If both fail, create a minimal Source note with the URL and mark status: needs-manual-extraction.

STEP 2 — CREATE SOURCE NOTE
Create a Source note in '01-Sources/' with extracted markdown content.
Frontmatter: title, source_url, source_type, author, date_captured, tags, status: processed.

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft, humanize, write to '02-Distilled/'.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Draft each, humanize, write to '03-Atomic/'.

STEP 5 — UPDATE MoCs
Search and update or create relevant MoCs. Humanize MoC prose.

STEP 6 — ARCHIVE
Move original inbox file to '06-Archive/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: PDFs and other files (Defuddle primary → LiteParse fallback)
# ═══════════════════════════════════════════════════════════
process_file() {
  local file="$1"
  local filename
  filename=$(basename "$file")
  local name_no_ext="${filename%.*}"

  run_with_retry "File — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a file from the inbox.
FILE: '$file'
FILENAME: '$filename'

STEP 1 — EXTRACT CONTENT
Try Defuddle first if applicable:
  defuddle parse '$file' --md
If Defuddle can't handle this file type or fails, FALL BACK to LiteParse:
  lit parse '$file' --format text -o /tmp/${name_no_ext}_extracted.md
LiteParse handles PDFs, DOCX, PPTX, XLSX, images (with OCR), and more.
Read the extracted text output.

STEP 2 — CREATE SOURCE NOTE
Move the original file to '01-Sources/' (keep for embedding if it's a PDF).
Create a Source note in '01-Sources/' with:
  - If PDF: embed it with ![[${filename}]]
  - Include extracted text in 'Original content' section
  - Frontmatter: title, author, source_type, tags, status: processed

STEP 3 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft, humanize, write to '02-Distilled/'.

STEP 4 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Draft each, humanize, write to '03-Atomic/'.

STEP 5 — UPDATE MoCs
Search and update or create relevant MoCs. Humanize MoC prose.

STEP 6 — ARCHIVE
Move the inbox entry (not the file in 01-Sources/) to '06-Archive/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# PROCESS: Clippings (already markdown)
# ═══════════════════════════════════════════════════════════
process_clipping() {
  local file="$1"

  run_with_retry "Clipping — file: $file" "
$COMMON_INSTRUCTIONS

TASK: Process a web clipper save.
FILE: '$file'

The file likely contains markdown captured by Obsidian Web Clipper,
possibly with frontmatter (source_url, title).

STEP 1 — CREATE SOURCE NOTE
If it has a source_url, create a Source note in '01-Sources/'.
If a Source for this URL already exists, update it.

STEP 2 — CREATE DISTILLED NOTE
$DISTILLED_STRUCTURE
Draft, humanize, write to '02-Distilled/'.

STEP 3 — CREATE ATOMIC NOTES
$ATOMIC_RULES
Draft each, humanize, write to '03-Atomic/'.

STEP 4 — UPDATE MoCs
Search and update or create relevant MoCs. Humanize MoC prose.

STEP 5 — ARCHIVE
Move the clipping to '06-Archive/processed-inbox/'.
"
}

# ═══════════════════════════════════════════════════════════
# MAIN LOOP
# ONLY processes raw/ and clippings/
# NEVER touches quick notes/
# ═══════════════════════════════════════════════════════════
log "Starting inbox processing..."

# Process everything in raw/
for file in "$VAULT_PATH/00-Inbox/raw"/*; do
  [ -f "$file" ] || continue

  if is_youtube_link "$file"; then
    process_youtube "$file"
  elif is_url_file "$file"; then
    process_url "$file"
  else
    process_file "$file"
  fi
done

# Process everything in clippings/
for file in "$VAULT_PATH/00-Inbox/clippings"/*.md; do
  [ -f "$file" ] || continue
  process_clipping "$file"
done

log "Inbox processing complete."
```

Make it executable:

```bash
chmod +x /path/to/MyVault/Meta/Scripts/process-inbox.sh
```

---

## Phase 5: Set Up the Cron Job

### Linux / macOS cron

```bash
crontab -e
```

```bash
# Every 30 minutes
*/30 * * * * VAULT_PATH="$HOME/MyVault" AGENT_CMD="claude -p" ANTHROPIC_API_KEY="sk-ant-..." TRANSCRIPT_API_KEY="your-key" /path/to/MyVault/Meta/Scripts/process-inbox.sh

# Every hour
0 * * * * VAULT_PATH="$HOME/MyVault" AGENT_CMD="claude -p" ANTHROPIC_API_KEY="sk-ant-..." TRANSCRIPT_API_KEY="your-key" /path/to/MyVault/Meta/Scripts/process-inbox.sh

# Twice daily (9am and 6pm)
0 9,18 * * * VAULT_PATH="$HOME/MyVault" AGENT_CMD="claude -p" ANTHROPIC_API_KEY="sk-ant-..." TRANSCRIPT_API_KEY="your-key" /path/to/MyVault/Meta/Scripts/process-inbox.sh
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
- [ ] Prose reads natural (no AI patterns)
- [ ] Atomic notes in `03-Atomic/` with 2-5 tags each
- [ ] MoCs updated or created in `04-MoCs/`
- [ ] Original file archived

### Test 2 — YouTube link (TranscriptAPI)

Create `00-Inbox/raw/test-yt.md`:
```
https://www.youtube.com/watch?v=dQw4w9WgXcQ
```

**Verify** transcript was fetched and converted to markdown, then processed through the full pipeline.

### Test 3 — PDF (Defuddle → LiteParse fallback)

Drop a PDF into `00-Inbox/raw/`. Run the processor.

**Verify** PDF moved to `01-Sources/`, embedded in Source note, full pipeline completed.

### Test 4 — Quick notes untouched

Create `00-Inbox/quick notes/my-thought.md`. Run the processor. **Verify the file is completely untouched.**

### Test 5 — Retry logic

Temporarily set an invalid API key. Run the processor. Check `Meta/Scripts/processing.log` for:
- Three retry attempts with increasing delays (5s, 10s, 20s)
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
| YouTube links | **TranscriptAPI** (youtube-full skill) | Agent marks as needs-transcript |
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
- Create target directories if missing
- Simplify the prompt if rate-limited
- Write to a temp location and move

---

## Troubleshooting

**"obsidian: command not found"** — Obsidian must be open. Enable CLI in Settings → General.

**"lit: command not found"** — `npm install -g @llamaindex/liteparse` and check your PATH.

**"defuddle: command not found"** — `npm install -g defuddle` and check your PATH.

**TranscriptAPI returns 401** — Check `TRANSCRIPT_API_KEY` is set correctly in your cron environment. Free tier gives 100 credits; check your dashboard at transcriptapi.com.

**Files stuck in `00-Inbox/failed/`** — These failed all 3 retry attempts. Check `processing.log` for the specific errors, then process manually or fix the issue and move them back to `raw/`.

**Tag sprawl** — Run `obsidian tags sort=count counts` to see the full tag list. The automation searches existing tags before creating new ones, but review weekly with Tag Wrangler.

**Humanizer not activating** — Verify `SKILL.md` exists in your agent's skills directory. The agent must be able to discover it at runtime.

**Quick notes getting processed** — The main loop explicitly only iterates `00-Inbox/raw/*` and `00-Inbox/clippings/*.md`. If quick notes are touched, something else is invoking the agent with different instructions.
