#!/usr/bin/env python3
"""Stage 3 helper: Build per-batch prompts from plans + extracted content + concept convergence."""
import json, os, sys
from datetime import date

def build_batch_prompt(batch_file, extract_dir, vault, entry_template_file, concept_template_file, common_instructions_file=None, convergence_file=None):
    with open(batch_file) as f:
        plans = json.load(f)

    with open(entry_template_file) as f:
        entry_structure = f.read()
    with open(concept_template_file) as f:
        concept_structure = f.read()

    # W8 fix: load common-instructions
    common = ""
    if common_instructions_file and os.path.exists(common_instructions_file):
        with open(common_instructions_file) as f:
            common = f.read()

    # Load concept convergence data (qmd semantic matches)
    convergence = {}
    if convergence_file and os.path.exists(convergence_file):
        with open(convergence_file) as f:
            convergence = json.load(f)

    # W5 fix: dynamic date
    today = date.today().isoformat()

    sources_block = ""
    for plan in plans:
        h = plan["hash"]
        extract_file = os.path.join(extract_dir, f"{h}.json")
        try:
            with open(extract_file) as ef:
                ext = json.load(ef)
        except (FileNotFoundError, json.JSONDecodeError):
            continue

        title = plan.get("title", "Untitled")
        content = ext.get("content", "")[:8000]
        source_type = plan.get("type", ext.get("type", "web"))
        author = plan.get("author", ext.get("author", "unknown"))
        url = ext.get("url", "")
        language = plan.get("language", "en")
        template = plan.get("template", "standard")
        tags = json.dumps(plan.get("tags", []))
        concept_updates = json.dumps(plan.get("concept_updates", []))
        concept_new = json.dumps(plan.get("concept_new", []))
        moc_targets = json.dumps(plan.get("moc_targets", []))

        # Concept convergence data (semantic matches from qmd)
        conv_matches = convergence.get(h, [])
        convergence_block = ""
        if conv_matches:
            conv_lines = "\n".join(
                f"  - {m['concept']} (score: {m['score']})" for m in conv_matches
            )
            convergence_block = f"\nCONCEPT_CONVERGENCE (semantic matches — check for duplicates before creating new):\n{conv_lines}\n"

        sources_block += f"""
══════════════════════════════════════
SOURCE: {title}
HASH: {h}
URL: {url}
TYPE: {source_type}
AUTHOR: {author}
LANGUAGE: {language}
TEMPLATE: {template}
TAGS: {tags}
CONCEPT_UPDATES: {concept_updates}
CONCEPT_NEW: {concept_new}
MOC_TARGETS: {moc_targets}{convergence_block}
CONTENT:
{content}
══════════════════════════════════════
"""

    prompt = f"""{common}

You are a wiki write agent. For each source below, create the vault files.

VAULT: {vault}

FILE NAMING: Use the title provided — it is already the correct content title.
NEVER use URL slugs, platform prefixes, or tweet IDs.

SOURCES:{sources_block}

---

FOR EACH SOURCE, DO THESE STEPS:

STEP 1 — CREATE SOURCE NOTE
Write to: 04-Wiki/sources/[title].md
Frontmatter: title, source_url, source_type, author, date_captured ({today}), tags, status: processed
Body: # Original content\n\n[full content]

STEP 2 — CREATE ENTRY NOTE
Write to: 04-Wiki/entries/[title].md
Use template from plan.
{entry_structure}

STEP 3 — CREATE/UPDATE CONCEPTS
For each concept in CONCEPT_NEW:
  Write to: 04-Wiki/concepts/[concept-name].md
{concept_structure}

For each concept in CONCEPT_UPDATES:
  Read the existing concept file, add the new source to its sources list and links.

STEP 4 — UPDATE MoCs
For each MoC in MOC_TARGETS:
  Read 04-Wiki/mocs/[moc-name].md
  Add wikilink to the new entry with 1-sentence summary

STEP 5 — UPDATE INDEX
Append entry and new concepts to 06-Config/wiki-index.md

STEP 6 — UPDATE EDGES
If relationships exist, append to 06-Config/edges.tsv

STEP 7 — ARCHIVE
Move original inbox file to 08-Archive-Raw/

CRITICAL RULES:
- NO stubs — every section must have real content
- Tags must be topic-specific English (never x.com, tweet, source)
- YAML wikilinks MUST be quoted: source: "[[note]]"
- Chinese content → write entries/concepts in Chinese
- YAML keys stay English, tag values stay English
- NEVER overwrite existing files — check first
- Content too large → chunk it, never write lazy disclaimers
- Draft content → humanize → write final file (I4: humanizer required)
- CONCEPT CONVERGENCE: For each concept in CONCEPT_NEW, check CONCEPT_CONVERGENCE
  semantic matches. If a match has score >0.5, that concept likely already exists —
  UPDATE it instead of creating a duplicate. Scores 0.2-0.5 are tangential —
  consider linking but don't merge unless substantively the same idea.

Write all files now."""

    return prompt

if __name__ == "__main__":
    batch_file = sys.argv[1]
    extract_dir = sys.argv[2]
    vault = sys.argv[3]
    entry_template = sys.argv[4]
    concept_template = sys.argv[5]
    common_instructions = sys.argv[6] if len(sys.argv) > 6 else None
    convergence_file = sys.argv[7] if len(sys.argv) > 7 else None

    prompt = build_batch_prompt(batch_file, extract_dir, vault, entry_template, concept_template, common_instructions, convergence_file)
    print(prompt)
