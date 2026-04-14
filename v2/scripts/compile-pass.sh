#!/usr/bin/env bash
# ============================================================================
# v2.2: Compile Pass — Incremental wiki improvement (Karpathy-style)
# ============================================================================
# Changes from v2.1:
#   - Sources common library (lib/common.sh)
#   - Fixed duplicate Operation 5/7 bug
#   - Added Operation 7: Typed edges construction (edges.tsv)
#   - Added Operation 8: Schema co-evolution (review agents.md)
#   - Git auto-commit after compile
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

acquire_lock "compile-pass" || exit 1
setup_directory_structure

log "=== Starting compile pass (v2.2) ==="

# Count notes for reporting
entry_count=$(find "$VAULT_PATH/04-Wiki/entries" -name '*.md' 2>/dev/null | wc -l)
concept_count=$(find "$VAULT_PATH/04-Wiki/concepts" -name '*.md' 2>/dev/null | wc -l)
moc_count=$(find "$VAULT_PATH/04-Wiki/mocs" -name '*.md' 2>/dev/null | wc -l)

log "Vault snapshot: $entry_count entries, $concept_count concepts, $moc_count MoCs"

# Build the compile pass prompt
prompt="
VAULT LOCATION: $VAULT_PATH
VAULT SNAPSHOT: $entry_count Entry notes, $concept_count Concept notes, $moc_count MoCs.

TASK: Perform a wiki compile pass — incremental improvement of the knowledge base.
You are working with notes in 04-Wiki/entries/, 04-Wiki/concepts/, and 04-Wiki/mocs/.
Do NOT reprocess the inbox.

Perform these operations in order:

## OPERATION 1: Cross-link analysis

Scan all Entry and Concept notes. Find notes that:
- Share the same source (check source: and entry_refs frontmatter)
- Share tags (scan tag frontmatter fields)
- Mention related concepts (scan headings and first paragraphs)

For each pair of related notes that don't already link to each other,
add a wikilink in the appropriate section:
- Entry notes: add to 'Linked concepts' section
- Concept notes: add to 'References' section (Related Concepts or Entries)
Search the note content to verify the link doesn't already exist.

## OPERATION 2: Concept Convergence (MERGE near-duplicates)

This is critical for maintaining a clean wiki vocabulary.

Scan 04-Wiki/concepts/ for concepts that:
- Have very similar titles or body content (fuzzy match, shared key terms)
- Cover the same idea from different Entry sources

For near-duplicates found:
1. Choose the OLDER concept as the canonical version.
2. Merge: copy all entry_refs from the duplicate into the canonical.
3. Update the canonical body if the duplicate adds useful content.
4. DELETE the duplicate concept note.
5. Update all Entry notes that linked to the duplicate — change their
   'Linked concepts' section to point to the canonical concept instead.

For truly duplicate concepts (identical): merge and delete.
For concepts that overlap partially: keep both but add cross-references.

## OPERATION 3: MoC Rebuild

For each existing MoC in 04-Wiki/mocs/:
1. Find all Concept and Entry notes that are tagged with the MoC's topic
   or mention it in their content.
2. Rebuild the MoC with this structure:

# <Topic Name> — Map of Content

## Overview
<2-3 sentence synthesized summary from the linked notes.>

## Core Concepts
- [[<Concept note>]] — <1-sentence summary>

## Related Entries
- [[<Entry note>]] — <1-sentence summary>

## Open Threads
- <Unanswered questions or gaps across linked notes>

3. Run the Humanizer skill before writing the MoC.
4. Update 'date_updated:' timestamp in frontmatter.

## OPERATION 4: Rebuild Wiki Index

Rebuild '06-Config/wiki-index.md' from scratch:
- Start with the header (keep the existing intro text)
- List every Entry note from 04-Wiki/entries/ with a 1-sentence summary
  Format: - [[EntryName]]: <1-sentence summary> (entry)
- List every Concept note from 04-Wiki/concepts/ with a 1-sentence summary
  Format: - [[ConceptName]]: <1-sentence summary> (concept)
- List every MoC from 04-Wiki/mocs/ with a 1-sentence summary
  Format: - [[MoCName]]: <1-sentence summary> (moc)
- Group under clear section headers: '## Entries', '## Concepts', '## Maps of Content'

## OPERATION 5: Duplicate Detection Report

Find Entry or Concept notes with very similar titles or content.
Create a report at 'Meta/Scripts/compile-duplicate-report.md':
- List pairs of potentially duplicate notes with their paths
- Include a brief reason (shared title terms, similar body)
- DO NOT auto-merge entries — only merge concepts (done in Operation 2)
- Leave entries for human review.

## OPERATION 6: Entry Template Assessment

Review Entry notes and check if any should use a non-standard template.
The `template:` frontmatter field selects the body structure:
- standard (default): Summary, ELI5 insights, Diagrams, Open questions, Linked concepts
- technical: Summary, Key Findings, Data/Evidence, Methodology, Limitations, Linked concepts
- comparison: Summary, Side-by-Side, Pros/Cons, Verdict, Linked concepts
- procedural: Summary, Prerequisites, Steps, Gotchas, Linked concepts

If an Entry's content clearly fits a different template better than 'standard',
note it in the compile report for human review. Do NOT auto-change templates.

## OPERATION 7: Write Compile Report + Log Entry

Write a compile report at 'Meta/Scripts/compile-report.md':
- Number of cross-links added
- Number of concepts merged
- Number of MoCs updated
- Number of potential duplicates found (not merged)
- Wiki index rebuilt: yes/no
- Timestamp

After the report, APPEND a structured entry to '06-Config/log.md':
  ## [YYYY-MM-DD] compile | Weekly compile pass
  - Cross-links added: N
  - Concept merges: N ([[ConceptA]] merged into [[ConceptB]])
  - MoCs rebuilt: N ([[Topic1]], [[Topic2]])
  - Wiki index rebuilt: yes
  - Duplicate entries flagged: N

## OPERATION 8: Typed Edges Construction

Scan all Entry, Concept, and MoC notes for relationships that should be
captured as typed edges in '06-Config/edges.tsv'.

Look for:
- Concepts that extend or build on other concepts (type: extends)
- Entries that contradict each other (type: contradicts)
- Concepts that support or provide evidence for other concepts (type: supports)
- Entries where one supersedes another with newer information (type: supersedes)
- Concepts tested or validated by specific entries (type: tested_by)
- Dependencies between concepts (type: depends_on)
- Inspiration chains (type: inspired_by)

For each relationship found, append a TSV line to '06-Config/edges.tsv':
  source<tab>target<tab>type<tab>description

Check for duplicates before appending. Each edge should be specific and evidence-based.

## OPERATION 9: Schema Co-Evolution

Read '06-Config/agents.md' and evaluate whether it still serves the wiki well.

Check:
1. Are the note structure templates still appropriate for the content in the vault?
2. Are the lint checks catching the right things? Missing anything?
3. Are there new patterns emerging in the vault that the schema should codify?
4. Should any workflows be added or modified?

Write a brief evaluation to 'Meta/Scripts/schema-review.md':
- Current schema strengths
- Suggested improvements (be specific)
- Any new patterns to codify
- Whether the schema should be updated

Do NOT modify agents.md directly — write the review for human approval.
This preserves the co-evolution principle: human and LLM collaborate on the schema.

IMPORTANT:
- ALL MoC and Concept prose must be humanized before writing.
- Use [[wikilinks]] for all internal links.
- Do NOT modify files in 07-WIP/.
- Do NOT delete Entry notes — only Concept duplicates are auto-merged.
"

log "Running compile pass with agent..."
if run_with_retry "Wiki compile pass (v2.2)" "$prompt"; then
  log "=== Compile pass completed successfully (v2.2) ==="
  auto_commit "compile" "Wiki compile pass ($entry_count entries, $concept_count concepts, $moc_count MoCs)"
  echo "Compile pass complete."
else
  log "=== Compile pass FAILED (v2.2) ==="
  echo "Compile pass failed. Check $LOG_FILE for details."
  exit 1
fi
