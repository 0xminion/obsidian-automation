# Obsidian AI-Automated PKM Wiki — Part 2: Automation & Skills Setup

> **Prerequisite:** Your vault folder structure from Part 1 must already exist. If not, complete Part 1 first.

---

## Phase 1: Install Prerequisites

### 1.1 Node.js (v18+)

Required for Defuddle, LiteParse, TranscriptAPI, and most agent runtimes. Install from [nodejs.org](https://nodejs.org).

### 1.2 Defuddle CLI — primary content extractor

```bash
npm install -g defuddle
```

### 1.3 LiteParse — fallback parser

```bash
npm install -g @llamaindex/liteparse
```

For office document conversion:

```bash
# macOS
brew install --cask libreoffice
# Ubuntu/Debian
sudo apt-get install libreoffice
```

### 1.4 Transcript providers — for YouTube links

**Primary — TranscriptAPI:** Sign up at [transcriptapi.com](https://transcriptapi.com) (100 free credits, no credit card required).

**Fallback — Supadata:** Sign up at [supadata.ai](https://supadata.ai).

```bash
export TRANSCRIPT_API_KEY="your-key"
export SUPADATA_API_KEY="your-key"
```

### 1.5 Humanizer skill

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/blader/humanizer.git ~/.claude/skills/humanizer
```

Adjust the path for your agent (Hermes: `~/.hermes/skills/`, Codex: `~/.codex/skills/`).

### 1.6 Choose and install your AI agent

| Agent | AGENT_CMD |
|---|---|
| Claude Code | `claude -p` (default, for cron/non-interactive) |
| Hermes Agent | `hermes run --prompt` |
| Codex CLI | `codex` |

---

## Phase 2: Install Agent Skills

### 2.1 Obsidian skills (kepano)

```bash
cd /path/to/MyVault
git clone https://github.com/kepano/obsidian-skills.git .claude/obsidian-skills
```

This installs: `obsidian-markdown`, `obsidian-cli`, `obsidian-bases`, `json-canvas`, `defuddle`.

### 2.2 YouTube transcript skill

```bash
npx skills add ZeroPointRepo/youtube-skills --skill youtube-full
```

### 2.3 Humanizer skill

Already installed in Phase 1.5.

### 2.4 Verify all skills

```
skills/
├── obsidian-skills/       # obsidian-markdown, obsidian-cli, defuddle
├── youtube-full/          # TranscriptAPI YouTube transcripts
└── humanizer/             # AI writing pattern removal
```

---

## Phase 3: Create Note Templates

Create these files in `Meta/Templates/`. The v2 templates live in this repo's `v2/templates/` directory.

**YAML note:** Wikilinks (`[[note-name]]`) in YAML frontmatter MUST always be quoted because YAML interprets `[[` as a nested list. Use `source: "[[note-name]]"` not `source: [[note-name]]`.

### `Meta/Templates/Source.md`

Full original content, stored as raw reference. Never humanized.

### `Meta/Templates/Entry.md`

Replaces the v1 Distilled template. **Same ELI5 structure users already know**, just renamed:
- Summary → ELI5 insights → Core insights / Other takeaways → Diagrams → Open questions → Linked concepts

The `source:` frontmatter field must use a quoted wikilink: `source: "[[Source note name]]"`.

### `Meta/Templates/Concept.md`

**New in v2.** Concepts replace v1's Atomic notes. Key differences:
- Concepts are **shared across multiple sources**, not owned by one Entry
- Concepts use YAML `entry_refs` with **quoted wikilinks** to reference all source Entries
- The compile pass **converges** duplicate concepts automatically — idempotent by design

```yaml
entry_refs:
  - "[[Entry 1]]"
  - "[[Entry 2]]"
```

### `Meta/Templates/MoC.md`

Topic hub with synthesized summaries. Points to Concepts and Entries:

```markdown
## Core Concepts
- [[Concept 1]] — 1-sentence summary

## Related Entries
- [[Entry 1]] — 1-sentence summary
```

### `Meta/Templates/Query.md`

Simple template for dropping questions. Place in `03-Queries/`.

### `06-Config/wiki-index.md`

**Replaces RAG.** Auto-maintained index of all Entries (by date, newest first) and Concepts (alphabetical). The agent navigates the wiki by reading this index and following wikilinks — no vector embeddings needed.

### `06-Config/tag-registry.md`

Canonical tag registry. Prevents tag sprawl by defining the `topic/*` and `type/*` namespaces.

---

## Phase 4: The AI Processing Script

The pipeline follows the same proven approach as v1: route input through the correct parser, generate notes, humanize them, and write to the wiki.

### Key features

- **Wiki, not pipeline** — Entries, Concepts, and MoCs form a navigable wiki. `wiki-index.md` replaces RAG.
- **Entry notes preserve the Distilled structure** — same ELI5 format, no relearning needed.
- **Concepts are shared across sources** — not owned by one Entry. Multiple entries can reference the same Concept via `entry_refs`.
- **Idempotency and concept convergence** — running the processor multiple times converges on the same set of Concepts. Duplicate concepts are merged by the compile pass.
- **Agent-agnostic** — defaults to `claude -p`, configurable via `AGENT_CMD` env var.
- **Retry logic** — exponential backoff (3 attempts). Failures go to `08-Archive-Raw/failed/`.
- **Humanization** — all prose in Entries, Concepts, and MoCs passes through the Humanizer skill.
- **Quoted wikilinks in YAML frontmatter** — all templates enforce this: `source: "[[note-name]]"`.

---

## Phase 5: Compile Pass, Query Mode, and Linting

These scripts make your wiki **self-improving over time**.

### `compile-pass.sh` — Incremental wiki recompilation

- **Cross-link**: finds Entries and Concepts sharing tags, adds missing wikilinks
- **Concept convergence**: merges duplicate Concepts across entries — idempotent
- **MoC refresh**: rebuilds MoCs with current summaries from linked notes
- **Outputs**: `Meta/Scripts/compile-report.md` with stats

### `query-vault.sh` — Q&A against the wiki

Drop a `.md` file in `03-Queries/` with your question. The agent:
1. Reads `wiki-index.md` for navigation context
2. Follows wikilinks to relevant Entries and Concepts
3. Synthesizes an answer with citations
4. Writes the answer as an Entry in `04-Wiki/entries/` (compound-back: updates existing pages with discovered connections), archives the query

**No RAG needed** — the wiki structure itself is the retrieval index.

### `lint-vault.sh` — Wiki health checks

- Orphaned notes (zero incoming wikilinks)
- Stale reviews (`status: review` older than 14 days)
- Broken wikilinks (links to notes that don't exist)
- Near-empty notes (<50 chars body)

---

## Phase 6: Set Up Cron

```bash
# Every 30 minutes: process inbox
*/30 * * * * VAULT_PATH="$HOME/MyVault" bash $HOME/MyVault/Meta/Scripts/process-inbox.sh

# Weekly compile pass (Sundays 2 AM) — converges concepts, cross-links
0 2 * * 0 VAULT_PATH="$HOME/MyVault" bash $HOME/MyVault/Meta/Scripts/compile-pass.sh

# Bi-weekly lint (Mondays and Thursdays 2 AM)
0 2 * * 1,4 VAULT_PATH="$HOME/MyVault" bash $HOME/MyVault/Meta/Scripts/lint-vault.sh
```

---

## Phase 7: Install Obsidian Plugins

| Plugin | Purpose |
|---|---|
| **Dataview** | Live tables for MoC notes, wiki queries |
| **Templater** | Advanced templating for manual note creation |
| **Tag Wrangler** | Bulk tag management (use with `tag-registry.md`) |
| **Obsidian Web Clipper** | Clip pages directly to `02-Clippings/` |
| **Auto Link Title** | Auto-fetch page titles on URL paste |
| **Periodic Notes** | Daily/weekly journaling notes |
