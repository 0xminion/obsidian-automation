# Obsidian AI-Automated PKM Wiki — Part 1: Vault Structure Setup

> Complete this part first. If you already have the wiki folder structure in place, skip directly to **Part 2: Automation & Skills Setup**.

---

## 1. Create a new vault (or use an existing one)

Open Obsidian → File → New Vault (or open your existing vault). Note the absolute path to the vault root — you'll need it in Part 2.

## 2. Create the folder structure

v2 replaces the pipeline model (Inbox → Sources → Distilled → Atomic → MoCs) with a **wiki model**. The folders reflect entries as wiki notes, concepts as shared ideas, and a flat wiki index instead of RAG.

```
MyVault/
├── wiki/                    # The knowledge wiki — everything you've learned
│   ├── entries/             # Distilled entries — one per source
│   ├── concepts/            # Shared concepts — span multiple sources
│   ├── mocs/                # Maps of Content — topic hubs
│   └── sources/             # Original source material (raw content)
├── 00-Inbox/
│   ├── raw/                 # URLs, PDFs, YouTube links — anything to be auto-processed
│   ├── quick notes/         # Personal notes — NEVER touched by automation
│   ├── clippings/           # Web clipper saves — auto-processed
│   ├── queries/             # Drop .md files with questions for Q&A
│   └── failed/              # Items that failed all retry attempts (manual review)
├── 05-WIP/                  # Your drafts + query answers — safe from automation
├── 06-Archive/
│   └── processed-inbox/     # Processed inbox items land here
├── Meta/
│   ├── Templates/           # Note templates (created in Part 2)
│   ├── Scripts/             # Automation scripts (created in Part 2)
│   ├── wiki-index.md        # Auto-maintained wiki index (replaces RAG)
│   └── tag-registry.md      # Canonical tag registry
└── queries/                 # Active and recent query files
```

Run this from your terminal:

```bash
cd /path/to/MyVault

mkdir -p wiki/{entries,concepts,mocs,sources}
mkdir -p "00-Inbox/raw" "00-Inbox/quick notes" "00-Inbox/clippings" "00-Inbox/queries" "00-Inbox/failed"
mkdir -p 05-WIP
mkdir -p 06-Archive/processed-inbox
mkdir -p Meta/{Templates,Scripts}
```

## 3. Understand the folder contracts

| Folder | Who writes to it | Automation touches it? |
|---|---|---|
| `wiki/sources/` | Automation | No further processing (stores originals) |
| `wiki/entries/` | Automation (humanized) + You | May be updated by compile pass |
| `wiki/concepts/` | Automation + You | **Converged by compile pass** — concepts are shared, not source-owned |
| `wiki/mocs/` | Automation (humanized) + You | May be appended by compile pass |
| `00-Inbox/raw/` | You (drop anything here) | **Yes** — processed and archived |
| `00-Inbox/quick notes/` | You (personal notes) | **Never** — completely off-limits |
| `00-Inbox/clippings/` | Web Clipper plugin | **Yes** — processed and archived |
| `00-Inbox/queries/` | You (drop questions here) | **Yes** — answered and archived |
| `00-Inbox/failed/` | Automation (moves failed items here) | No further processing (manual review) |
| `05-WIP/` | You | **Never** |
| `06-Archive/` | Automation (moves processed items here) | No further processing |
| `Meta/` | Part 2 setup | **Never** (scripts and templates live here) |

## 4. Key v2 structural differences from v1

| v1 | v2 |
|---|---|
| `02-Distilled/` notes | `wiki/entries/` — same ELI5 structure, folder renamed |
| `03-Atomic/` notes | `wiki/concepts/` — now shared across sources, not owned by one entry |
| `04-MoCs/` note links | `wiki/mocs/` — same MoC structure, points to Concepts not Atomics |
| `Meta/Scripts/url-index.tsv` | `Meta/wiki-index.md` — auto-maintained index replaces RAG |
| No tag management | `Meta/tag-registry.md` — canonical tag registry prevents sprawl |
| Atomic notes owned by source | Concepts are shared, converge across entries |

## 5. The Wiki Model (Karpathy-Aligned Philosophy)

v2 is aligned with the "wiki, not pipeline" philosophy:

- **Entries** (`wiki/entries/`) are what you previously knew as Distilled notes. Same structure. Same ELI5 format. Just renamed for clarity.
- **Concepts** (`wiki/concepts/`) are ideas that span multiple sources. They are **not owned by a single entry**. Multiple entries can reference the same Concept. The compile pass converges duplicate concepts automatically.
- **MoCs** (`wiki/mocs/`) are topic hubs linking Concepts and Entries with synthesized summaries.
- **Sources** (`wiki/sources/`) store original content. Never humanized. Full fidelity.
- **wiki-index.md** replaces the need for RAG. The entire wiki is your retrieval index — the agent navigates entries, concepts, and MoCs by following wikilinks.

## 6. Enable Obsidian CLI

### Option A — Obsidian Desktop App (CLI requires running app)

Go to **Settings → General → Enable CLI** (requires Obsidian 1.8+). Verify it works:

```bash
obsidian help
```

### Option B — Obsidian Headless Client (recommended for automation)

The [obsidian-headless](https://github.com/obsidianmd/obsidian-headless) client runs without the desktop app.

```bash
npm install -g obsidian-headless
ob login
ob sync-list-remote
```

## 7. Enable Community Plugins

Go to **Settings → Community plugins → Turn on community plugins**. You'll install specific plugins in Part 2.

---

**Your vault structure is ready. Proceed to Part 2: Automation & Skills Setup.**
