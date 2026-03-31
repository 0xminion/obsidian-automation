# Obsidian AI-Automated PKM Vault

Automated knowledge management system that turns raw web content, PDFs, and YouTube videos into a structured vault of Source, Distilled, and Atomic notes — all humanized to sound natural.

```
00-Inbox/          →  You drop URLs, PDFs, YouTube links here
01-Sources/        ←  Full original content stored here (not humanized)
02-Distilled/      ←  AI summaries with ELI5 insights (humanized)
03-Atomic/         ←  One idea per evergreen note (humanized)
04-MoCs/           ←  Topic hub notes (humanized)
05-WIP/            ←  Your drafts (never touched by automation)
06-Archive/        ←  Processed inbox items
Meta/
├── Scripts/           process-inbox.sh + Dashboard.md
└── Templates/         Source.md, Distilled.md, Atomic.md, MoC.md
```

## Quick Start

### 1. Prerequisites

```bash
# Node.js 18+ (for Defuddle, LiteParse, TranscriptAPI)
node --version  # >= 18

# Node.js 22+ (for obsidian-headless sync client)
node --version  # >= 22 if using ob sync

# AI Agent — pick one:
# Claude Code (default):  npm install -g @anthropic-ai/claude-code
# Hermes Agent:           curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
# Codex CLI:              npm install -g @openai/codex

# Obsidian CLI (desktop app) — open Obsidian → Settings → General → Enable CLI
obsidian help

# Obsidian Headless Client (for headless/cron sync — Node 22+)
npm install -g obsidian-headless
ob login
```

### 2. Install tools

```bash
# Defuddle (web content extraction)
npm install -g defuddle

# LiteParse (PDF/DOCX fallback)
npm install -g @llamaindex/liteparse

# LibreOffice (office document conversion for LiteParse)
# macOS
brew install --cask libreoffice
# Ubuntu/Debian
sudo apt-get install libreoffice
```

### 3. Install agent skills

```bash
mkdir -p ~/.hermes/skills

# Humanizer
git clone https://github.com/blader/humanizer.git ~/.hermes/skills/humanizer

# Obsidian skills
git clone https://github.com/kepano/obsidian-skills.git ~/.hermes/skills/obsidian-kepano

# TranscriptAPI (YouTube transcripts)
# 1. Sign up at https://transcriptapi.com (100 free credits, no card)
# 2. Install the skill
cd ~/.hermes/skills && clawhub install transcriptapi
# Or manually: git clone https://github.com/ZeroPointRepo/youtube-skills.git
```

### 4. Set up your vault

```bash
# Create vault structure
mkdir -p ~/MyVault
cd ~/MyVault
mkdir -p "00-Inbox/raw" "00-Inbox/quick notes" "00-Inbox/clippings"
mkdir -p 01-Sources 02-Distilled 03-Atomic 04-MoCs 05-WIP
mkdir -p 06-Archive/processed-inbox
mkdir -p Meta/Templates Meta/Scripts
mkdir -p .claude

# Enable CLI: Obsidian → Settings → General → Enable CLI
obsidian help
```

### 5. Install templates and the processor script

Copy the files from this repo into your vault:

```bash
# Templates
cp docs/Part2-Automation-Skills-Setup.md ~/MyVault/
# (The templates are embedded in Part2 — extract them to Meta/Templates/)

# Processor script
chmod +x scripts/process-inbox.sh
cp scripts/process-inbox.sh ~/MyVault/Meta/Scripts/
cp scripts/Dashboard.md ~/MyVault/Meta/Dashboard.md
```

### 6. Configure transcript providers

```bash
# Primary: TranscriptAPI
# Sign up at https://transcriptapi.com and get your API key
# Set your API key as an environment variable:
export TRANSCRIPT_API_KEY="your-key-here"
# Add to your shell profile (~/.bashrc, ~/.zshrc) so it persists.
```

### 7. Run the pipeline

```bash
# Run the processor
VAULT_PATH="$HOME/MyVault" bash ~/MyVault/Meta/Scripts/process-inbox.sh
```

### 8. Automate with cron

```bash
# Every 30 minutes
crontab -e
*/30 * * * * VAULT_PATH="$HOME/MyVault" TRANSCRIPT_API_KEY="your-key" $HOME/MyVault/Meta/Scripts/process-inbox.sh
```

Or use Hermes Agent's built-in scheduler:

```bash
hermes schedule add \
  --name "inbox-processor" \
  --interval "30m" \
  --command "Process all files in 00-Inbox/raw/ and 00-Inbox/clippings/" \
  --workdir "$HOME/MyVault"
```

## Obsidian Plugins

Install via Settings → Community plugins → Browse:

| Plugin | Purpose |
|---|---|
| **Dataview** | Live tables for the Dashboard |
| **Templater** | Advanced templating for manual note creation |
| **Tag Wrangler** | Bulk tag management to prevent tag sprawl |
| **Obsidian Web Clipper** | Clip pages directly to `00-Inbox/clippings/` |
| **Auto Link Title** | Auto-fetch page titles on URL paste |
| **Periodic Notes** | Daily/weekly journaling notes |

## How the Pipeline Works

### File routing

| Input | Parser | Notes |
|---|---|---|
| URL (`.md`/`.txt` containing a single URL) | Defuddle primary, LiteParse fallback | |
| PDF / DOCX / PPTX / other files | Defuddle primary, LiteParse fallback | |
| YouTube link (single-URL file) | TranscriptAPI | |
| Web clipper save | Direct passthrough | Already markdown |

### Note types

**`01-Sources/`** — Full original content. Never humanized.

**`02-Distilled/`** — AI summary with exact structure:
1. `## Summary` — 3-5 sentence plain-language overview
2. `## ELI5 insights` — Core + Other takeaways, explained like you're 12
3. `## Diagrams` — Mermaid diagrams if content warrants them, else `N/A`
4. `## Open questions` — Gaps and assumptions
5. `## Linked concepts` — Wikilinks to related notes

**`03-Atomic/`** — One idea per note. 2-5 sentences, 2-5 tags. Always linked back to Source and Distilled.

**`04-MoCs/`** — Topic hubs that link to related Atomic and Distilled notes.

### Retry Logic

Every processing call is wrapped in `run_with_retry` with exponential backoff (3 attempts, 5s/10s delays). On failure, the agent receives retry instructions suggesting alternative approaches (e.g., LiteParse fallback, different API parameters). Files that fail all retries are moved to `00-Inbox/failed/` for manual review.

### Humanization

All prose in `02-Distilled/`, `03-Atomic/`, and `04-MoCs/` passes through the Humanizer skill before writing. This removes AI patterns: inflated significance, em dash overuse, rule of three, AI vocabulary, etc.

## Repository Structure

```
obsidian-automation/
├── docs/
│   ├── Part1-Vault-Structure-Setup.md    # Step-by-step vault creation
│   └── Part2-Automation-Skills-Setup.md  # Full setup guide (tools, skills, cron)
├── scripts/
│   ├── process-inbox.sh                  # Main automation script
│   └── Dashboard.md                      # Dataview dashboard template
└── skills/                               # Skill references
    ├── obsidian-markdown.md
    ├── obsidian-cli.md
    ├── humanizer.md
    └── transcriptapi.md
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `obsidian: command not found` | Open Obsidian, enable CLI in Settings → General |
| `ob: command not found` | `npm install -g obsidian-headless` (requires Node 22+) |
| `defuddle: command not found` | `npm install -g defuddle` |
| `lit: command not found` | `npm install -g @llamaindex/liteparse` |
| TranscriptAPI 401 | Check `TRANSCRIPT_API_KEY` env var |
| TranscriptAPI 402/404 | Check credits at transcriptapi.com; retry logic will attempt alternative approaches |
| Files stuck in `00-Inbox/failed/` | Check `Meta/Scripts/processing.log` |
| Tag sprawl | Weekly: run `obsidian tags sort=count counts` and merge with Tag Wrangler |
| Quick notes touched | Only `raw/` and `clippings/` are processed — check script invocation |

## Dependencies Summary

| Tool | Version | Purpose |
|---|---|---|
| Node.js | 18+ | Runtime for Defuddle, LiteParse, TranscriptAPI |
| Node.js | 22+ | Required for obsidian-headless (`ob`) |
| Obsidian CLI (`obsidian`) | 1.8+ | Note creation, search, tagging (desktop app needed) |
| Obsidian Headless (`ob`) | latest | Sync + publish without desktop app |
| Defuddle | latest | Web content extraction |
| LiteParse | latest | PDF/DOCX/PPTX parsing with OCR |
| LibreOffice | latest | Office format conversion for LiteParse |
| TranscriptAPI | — | YouTube transcript fetching |
| Humanizer | — | AI pattern removal from generated prose |
