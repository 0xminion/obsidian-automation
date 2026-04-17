#!/usr/bin/env python3
"""Stage 3 helper: Build per-batch prompts from plans + extracted content + concept convergence.

Composes the agent prompt from modular .prompt files instead of inline strings.
This is the single source of truth for prompt construction — rules live in prompts/.
"""
import json, os, sys
from datetime import date

PROMPT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'prompts')


def load_prompt(name, prompt_dir=None):
    """Load a prompt file by name. Returns content or empty string."""
    d = prompt_dir or PROMPT_DIR
    path = os.path.join(d, f"{name}.prompt")
    if os.path.exists(path):
        with open(path) as f:
            return f.read()
    return ""


def build_batch_prompt(batch_file, extract_dir, vault, entry_template_file,
                       concept_template_file, common_instructions_file=None,
                       convergence_file=None, prompt_dir=None):
    with open(batch_file) as f:
        plans = json.load(f)

    with open(entry_template_file) as f:
        entry_structure = f.read()
    with open(concept_template_file) as f:
        concept_structure = f.read()

    # Load common-instructions (shared rules for all agents)
    common = ""
    if common_instructions_file and os.path.exists(common_instructions_file):
        with open(common_instructions_file) as f:
            common = f.read()
    # Substitute vault path placeholder
    common = common.replace("{VAULT_PATH}", vault)

    # Load batch-create prompt template (workflow steps + agent framing)
    batch_create = load_prompt("batch-create", prompt_dir)

    # Load concept convergence data (qmd semantic matches)
    convergence = {}
    if convergence_file and os.path.exists(convergence_file):
        with open(convergence_file) as f:
            convergence = json.load(f)

    today = date.today().isoformat()

    # Build per-source data blocks
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
            convergence_block = (
                f"\nCONCEPT_CONVERGENCE "
                f"(semantic matches — check for duplicates before creating new):\n"
                f"{conv_lines}\n"
            )

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

    # Compose: common-instructions + batch-create (with variable substitution)
    # The batch-create prompt uses {VAULT}, {SOURCES_BLOCK}, {ENTRY_STRUCTURE},
    # {CONCEPT_STRUCTURE}, {TODAY} placeholders.
    batch_filled = batch_create
    batch_filled = batch_filled.replace("{VAULT}", vault)
    batch_filled = batch_filled.replace("{SOURCES_BLOCK}", sources_block)
    batch_filled = batch_filled.replace("{ENTRY_STRUCTURE}", entry_structure)
    batch_filled = batch_filled.replace("{CONCEPT_STRUCTURE}", concept_structure)
    batch_filled = batch_filled.replace("{TODAY}", today)

    # Final prompt: shared rules first, then agent-specific instructions
    prompt = f"""{common}

{batch_filled}"""

    return prompt


if __name__ == "__main__":
    if len(sys.argv) < 6:
        print("Usage: build_batch_prompt.py <batch_file> <extract_dir> <vault> <entry_template> <concept_template> [common_instructions] [convergence_file]", file=sys.stderr)
        sys.exit(1)

    batch_file = sys.argv[1]
    extract_dir = sys.argv[2]
    vault = sys.argv[3]
    entry_template = sys.argv[4]
    concept_template = sys.argv[5]
    common_instructions = sys.argv[6] if len(sys.argv) > 6 else None
    convergence_file = sys.argv[7] if len(sys.argv) > 7 else None

    prompt = build_batch_prompt(
        batch_file, extract_dir, vault, entry_template, concept_template,
        common_instructions, convergence_file
    )
    print(prompt)
