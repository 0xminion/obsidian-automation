# Obsidian AI-Automated PKM Vault — Part 1: Vault Structure Setup

> Complete this part first. If you already have this folder structure in place, skip directly to **Part 2: Automation & Skills Setup**.

---

## 1. Create a new vault (or use an existing one)

Open Obsidian → File → New Vault (or open your existing vault). Note the absolute path to the vault root — you'll need it in Part 2.

## 2. Create the folder structure

```
MyVault/
├── 00-Inbox/
│   ├── raw/                   # URLs, PDFs, YouTube links — anything to be auto-processed
│   ├── quick notes/           # Personal notes — NEVER touched by automation
│   └── clippings/             # Web clipper saves — auto-processed
├── 01-Sources/                # Full original source material (stored as-is)
├── 02-Distilled/              # AI-generated summaries (humanized before writing)
├── 03-Atomic/                 # One idea per note, evergreen (humanized before writing)
├── 04-MoCs/                   # Maps of Content — topic index hubs (humanized before writing)
├── 05-WIP/                    # Work in progress, drafts, projects
├── 06-Archive/                # Completed or retired content
│   └── processed-inbox/       # Processed inbox items land here
├── Meta/
│   ├── Templates/             # Note templates (created in Part 2)
│   └── Scripts/               # Automation scripts (created in Part 2)
└── .claude/                   # Agent skills directory (rename for your agent)
```

Run this from your terminal:

```bash
cd /path/to/MyVault

mkdir -p "00-Inbox/raw" "00-Inbox/quick notes" "00-Inbox/clippings"
mkdir -p 01-Sources 02-Distilled 03-Atomic 04-MoCs 05-WIP
mkdir -p 06-Archive/processed-inbox
mkdir -p Meta/{Templates,Scripts}
mkdir -p .claude
```

## 3. Understand the folder contracts

| Folder | Who writes to it | Automation touches it? |
|---|---|---|
| `00-Inbox/raw/` | You (drop anything here) | **Yes** — processed and archived |
| `00-Inbox/quick notes/` | You (personal notes) | **Never** — completely off-limits |
| `00-Inbox/clippings/` | Web Clipper plugin | **Yes** — processed and archived |
| `01-Sources/` | Automation | No further processing (stores originals) |
| `02-Distilled/` | Automation (humanized) | No further processing |
| `03-Atomic/` | Automation (humanized) + You | No further processing |
| `04-MoCs/` | Automation (humanized) + You | May be appended to by automation |
| `05-WIP/` | You | **Never** |
| `06-Archive/` | Automation (moves processed items here) | No further processing |
| `Meta/` | Part 2 setup | **Never** (scripts and templates live here) |

## 4. Enable Obsidian CLI

The automation uses the Obsidian CLI to create, search, and manage notes programmatically. Two options:

### Option A — Obsidian Desktop App (CLI requires running app)

Go to **Settings → General → Enable CLI** (requires Obsidian 1.8+). Verify it works:

```bash
obsidian help
```

**Limitation:** Obsidian must remain open for CLI commands to work. Not suitable for headless/cron environments.

### Option B — Obsidian Headless Client (recommended for automation)

The [obsidian-headless](https://github.com/obsidianmd/obsidian-headless) client runs without the desktop app — ideal for servers and cron jobs.

```bash
# Requires Node.js 22+
npm install -g obsidian-headless

# Login to your Obsidian account
ob login

# List your remote vaults
ob sync-list-remote

# Setup sync for your vault
cd ~/MyVault
ob sync-setup --vault "My Vault"

# Run continuous sync (keeps local vault in sync with remote)
ob sync --continuous &
```

> **Note:** `ob` handles sync (uploading/downloading changes). The **desktop CLI** (`obsidian`) handles note operations. In a fully headless setup, use `ob sync` to keep the vault updated, then run the automation script against the local vault files directly. The `process-inbox.sh` script uses direct file operations (cp, mv, cat, mkdir) so it works entirely without Obsidian running.

### Which to use?

| Feature | `obsidian` CLI (desktop) | `ob` (headless) |
|---|---|---|
| Note creation/search | ✓ | — |
| Headless/cron | ✗ (needs app open) | ✓ |
| Sync with remote vault | ✗ | ✓ |
| Works on server | ✗ | ✓ |

Both can coexist. The automation script uses direct file I/O and does not depend on either CLI for core functionality.

## 5. Enable Community Plugins

Go to **Settings → Community plugins → Turn on community plugins**. You'll install specific plugins in Part 2.

---

**Your vault structure is ready. Proceed to Part 2: Automation & Skills Setup.**
