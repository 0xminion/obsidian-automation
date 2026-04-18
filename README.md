# obsidian-automated PKM vault — Karpathy-style wiki

Automated knowledge management that turns web content, YouTube videos, PDFs, and podcasts into a self-organizing Obsidian wiki. Inspired by Andrej Karpathy's "LLM Knowledge Bases" approach.

3-stage pipeline: extract → plan → create. Parallel agents, semantic concept search, bilingual (EN/ZH) support.

## Setup

```bash
git clone https://github.com/0xminion/obsidian-automation.git
cd obsidian-automation
./setup.sh ~/MyVault
# Edit API keys:
nano ~/MyVault/Meta/Scripts/.env
```

`setup.sh` creates directories, copies scripts, checks dependencies, and creates a `run.sh` wrapper.

### Prerequisites

**Required:**
- bash 4.4+, jq, curl, python3
- hermes agent (gateway running)

**Optional (graceful degradation if missing):**
- `qmd` — semantic concept search ([setup](#semantic-search))
- `yt-dlp` + `ffmpeg` — YouTube/audio download
- `defuddle` — clean web extraction
- `ob` — Obsidian vault sync

### API keys (.env)

```bash
# Required for YouTube transcripts:
TRANSCRIPT_API_KEY=sk_...
SUPADATA_API_KEY=sd_...

# Required for podcast transcription:
ASSEMBLYAI_API_KEY=...

# Optional:
VAULT_PATH=$HOME/MyVault   # default if not set
AGENT_CMD=hermes            # default
PARALLEL=3                  # default
```

## Usage

```bash
# Drop a URL
echo 'https://example.com/article' > ~/MyVault/01-Raw/my-source.url

# Run pipeline
cd ~/MyVault && ./run.sh

# Check results
ls ~/MyVault/04-Wiki/entries/
```

That's it. URLs in `01-Raw/` → pipeline creates Sources, Entries, Concepts, and updates MoCs in `04-Wiki/`.

### Pipeline flags

```bash
./run.sh                      # default: 3 parallel agents
./run.sh --parallel 5         # more parallelism
./run.sh --dry-run            # preview without executing
./run.sh --review             # run stages 1+2, save plans for review
./run.sh --resume             # skip stages 1+2, use reviewed plans
```

### Manual stage execution

If `process-inbox.sh` fails mid-pipeline, run stages individually:

```bash
HASH=$(echo -n "$VAULT_PATH" | md5sum | cut -c1-8)
export PIPELINE_TMPDIR="/tmp/obsidian-extracted-${HASH}"

cd ~/MyVault
VAULT_PATH=$(pwd) bash Meta/Scripts/stage1-extract.sh
VAULT_PATH=$(pwd) bash Meta/Scripts/stage2-plan.sh
VAULT_PATH=$(pwd) bash Meta/Scripts/stage3-create.sh --parallel 3

# Post-processing (if stage 3 timed out):
bash Meta/Scripts/reindex.sh && ob sync --path "$(pwd)"
```

**Important:** `PIPELINE_TMPDIR` must be set so stages share the same temp directory. `process-inbox.sh` sets this automatically; manual runs must export it explicitly.

## Vault structure

```
01-Raw/              ← drop URLs, PDFs, files here
02-Clippings/        ← web clipper saves (already markdown)
03-Queries/          ← drop .md files with questions
04-Wiki/
├── sources/         ← full original content
├── entries/         ← summaries + insights (humanized)
├── concepts/        ← shared vocabulary (evergreen)
└── mocs/            ← topic hubs
05-Outputs/          ← Q&A responses, visualizations
06-Config/           ← wiki-index, edges, tags, log
07-WIP/              ← your drafts (untouched by automation)
08-Archive-Raw/      ← processed inbox items
09-Archive-Queries/  ← answered queries
Meta/
├── Scripts/         ← pipeline scripts
├── lib/             ← shared shell library
├── prompts/         ← agent prompt templates
└── Templates/       ← note templates
```

## Note structures

**Entries** (English):
```
Summary → Core insights → Other takeaways → Diagrams → Open questions → Linked concepts
```

**Entries** (Chinese):
```
摘要 → 核心发现 → 其他要点 → 图表 → 开放问题 → 关联概念
```

**Concepts** (evergreen):
```
Core concept → Context (flowing prose) → Links
```

**MoCs**: Topic-specific bilingual sections. Cross-references with ASCII diagram.

## Naming conventions

- Chinese titles → Chinese filenames
- English titles → kebab-case
- Papers → paper title
- Tweets → topic (not tweet ID)
- YouTube → video title
- Podcasts → episode title
- ❌ Never: URL slugs, platform prefixes, handles

## Scripts

| Script | Purpose |
|---|---|
| `setup.sh` | One-command vault setup |
| `process-inbox.sh` | **Primary pipeline.** 3-stage: Extract → Plan → Create |
| `review-pass.sh` | Review entries: `--untouched`, `--last N`, `--topic TAG` |
| `compile-pass.sh` | Cross-linking, concept merge, edges, schema review |
| `query-vault.sh` | Q&A with compound-back |
| `lint-vault.sh` | 12 health checks |
| `vault-stats.sh` | Dashboard: size, growth, health |
| `reindex.sh` | Full rebuild of wiki-index.md |
| `validate-output.sh` | Validates frontmatter, sections, stubs, tags. Supports `--fix` |
| `setup-qmd.sh` | One-time qmd setup |
| `extract-transcript.sh` | Standalone transcript extraction |

## Pipeline details

```
Stage 1: Extract (shell, ~1-5s per URL)
  → Pure shell: defuddle / transcriptapi / curl
  → No LLM, parallel via xargs -P4

Stage 2: Plan (1 agent, ~30-60s)
  → Semantic concept pre-search via qmd
  → Bilingual detection, template selection, tag suggestions

Stage 3: Create (N parallel agents, ~60-120s per source)
  → Write Source + Entry + Concept + MoC files
  → Concept convergence via pre-fetched qmd matches
  → Output validation runs automatically
```

### Timeouts

Stage 3 agents have a 900s internal timeout. For terminal calls, use ≥960s. Stage 2 budgets ~400s (includes qmd per-plan queries at 300s each).

### Extraction chain

| Source | Chain |
|---|---|
| URLs | defuddle → liteparse → browser |
| X/Twitter | defuddle → liteparse → browser |
| YouTube | TranscriptAPI → Supadata → faster-whisper |
| Podcasts | AssemblyAI → whisper |
| PDFs | liteparse → OCR |

## Semantic search

```bash
# One-time setup
VAULT_PATH=~/MyVault bash Meta/Scripts/setup-qmd.sh

# Manual commands
qmd update                        # re-index after adding concepts
qmd query "prediction markets" --json -n 5 -c concepts
```

Uses Qwen3-Embedding-0.6B-Q8 for semantic similarity. Falls back gracefully if not installed.

## Typed edges

Relationships stored in `06-Config/edges.tsv` (4-column: source, target, type, description).

Types: extends, contradicts, supports, supersedes, tested_by, depends_on, inspired_by

Built automatically during `compile-pass.sh`.

## Critical rules

1. Never touch `07-WIP/`
2. Never overwrite existing notes — use collision detection
3. No stubs — every section needs real content at creation
4. Tags: topic-specific English only (never `x.com`, `tweet`, `source`)
5. Chinese body stays Chinese in all 04-Wiki notes
6. YAML wikilinks must be quoted: `source: "[[note]]"`
7. File names match content language
8. Never use URL slugs as filenames

## Testing

```bash
cd ~/MyVault
bash Meta/Scripts/tests/run_all_tests.sh           # all tests
bash Meta/Scripts/tests/run_all_tests.sh stage1     # single suite
```

Suites: `stage1`, `stage2`, `stage3`, `integration`, `edge`, `qmd`

## Recommended workflow

**Daily:** Drop sources in `01-Raw/`, run `./run.sh`

**Weekly:** `compile-pass.sh` → `review-pass.sh --untouched` → `lint-vault.sh`

**Monthly:** `reindex.sh` if lint flags drift (usually auto-rebuilt)
