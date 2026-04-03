#!/usr/bin/env bash
# ============================================================================
# v2: Compile Pass — Incremental wiki improvement (Karpathy-style)
# ============================================================================
# Scans 02-Wiki/entries/, 02-Wiki/concepts/, 02-Wiki/mocs/ and performs a
# re-compilation to improve the wiki over time.
#
# What this does:
# 1. Cross-links: finds Entry/Concept notes that reference the same Source
#    or share tags, adds missing wikilinks between them.
# 2. Concept convergence: checks for near-duplicate Concepts and merges them.
# 3. MoC refresh: rebuilds MoC notes with updated summaries from linked notes.
# 4. Wiki index: rebuilds 04-Config/wiki-index.md from scratch.
# 5. Duplicate detection: finds similar Concept/Entry notes and suggests merges.
# ============================================================================

set -uo pipefail

VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
LOG_FILE="$VAULT_PATH/Meta/Scripts/processing.log"
LOCK_FILE="/tmp/obsidian-compile-pass-v2-$(echo "$VAULT_PATH" | md5sum | cut -c1-8).lock"
AGENT_CMD="${AGENT_CMD:-claude -p}"

mkdir -p "$VAULT_PATH/Meta/Scripts"

log() { echo "$(date): $1" >> "$LOG_FILE"; }

# Prevent overlapping runs
if [ -f "$LOCK_FILE" ]; then
  echo "$(date): Compile pass already running. Exiting." >> "$LOG_FILE"
  exit 0
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

log "=== Starting compile pass (v2) ==="

# Count notes for reporting
entry_count=$(find "$VAULT_PATH/02-Wiki/entries" -name '*.md' 2>/dev/null | wc -l)
concept_count=$(find "$VAULT_PATH/02-Wiki/concepts" -name '*.md' 2>/dev/null | wc -l)
moc_count=$(find "$VAULT_PATH/02-Wiki/mocs" -name '*.md' 2>/dev/null | wc -l)

log "Vault snapshot: $entry_count entries, $concept_count concepts, $moc_count MoCs"

# Retry with exponential backoff (same pattern as process-inbox.sh)
MAX_RETRIES=3

RETRY_ADVICE="
RETRY CONTEXT: Previous attempt failed. Try alternatives:
- If note operations failed, verify the target directory exists.
- If search failed, try simpler keywords.
- If rate-limited, use a shorter prompt.
- If file write failed, write to /tmp first, then mv.
Be resourceful. Find a way."

run_with_retry() {
  local description="$1"
  local prompt="$2"
  local attempt=1
  local delay=5

  while [ $attempt -le $MAX_RETRIES ]; do
    log "Attempt $attempt/$MAX_RETRIES: $description"

    local result=0
    cd "$VAULT_PATH" && $AGENT_CMD "$prompt" 2>> "$LOG_FILE" || result=$?

    if [ $result -eq 0 ]; then
      log "SUCCESS: $description"
      return 0
    fi

    log "FAILED (exit $result): $description — attempt $attempt/$MAX_RETRIES"

    if [ $attempt -lt $MAX_RETRIES ]; then
      log "Waiting ${delay}s before retry..."
      sleep $delay
      delay=$((delay * 2))
      prompt="${prompt}${RETRY_ADVICE}"
    fi

    attempt=$((attempt + 1))
  done

  log "GIVING UP after $MAX_RETRIES attempts: $description"
  return 1
}

# Build the compile pass prompt
prompt="
VAULT LOCATION: $VAULT_PATH
VAULT SNAPSHOT: $entry_count Entry notes, $concept_count Concept notes, $moc_count MoCs.

TASK: Perform a wiki compile pass — incremental improvement of the knowledge base.
You are working with notes in 02-Wiki/entries/, 02-Wiki/concepts/, and 02-Wiki/mocs/.
Do NOT reprocess the inbox.

Perform these operations in order:

## OPERATION 1: Cross-link analysis

Scan all Entry and Concept notes. Find notes that:
- Share the same source (check source: and entry_refs frontmatter)
- Share tags (use 'obsidian tags sort=count counts')
- Mention related concepts (scan headings and first paragraphs)

For each pair of related notes that don't already link to each other,
add a wikilink in the appropriate section:
- Entry notes: add to 'Linked concepts' section
- Concept notes: add to 'References' section (Related Concepts or Entries)
Use 'obsidian search' to verify the link doesn't already exist in the note.

## OPERATION 2: Concept Convergence (MERGE near-duplicates)

This is critical for maintaining a clean wiki vocabulary.

Scan 02-Wiki/concepts/ for concepts that:
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

This keeps the wiki vocabulary clean — one concept, one note.

## OPERATION 3: MoC Rebuild

For each existing MoC in 02-Wiki/mocs/:
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

Rebuild '04-Config/wiki-index.md' from scratch:
- Start with the header (keep the existing intro text)
- List every Entry note from 02-Wiki/entries/ with a 1-sentence summary
  Format: - [[EntryName]]: <1-sentence summary> (entry)
- List every Concept note from 02-Wiki/concepts/ with a 1-sentence summary
  Format: - [[ConceptName]]: <1-sentence summary> (concept)
- Group under clear section headers: '## Entries' and '## Concepts'

## OPERATION 5: Duplicate Detection Report

Find Entry or Concept notes with very similar titles or content.
Create a report at 'Meta/Scripts/compile-duplicate-report.md':
- List pairs of potentially duplicate notes with their paths
- Include a brief reason (shared title terms, similar body)
- DO NOT auto-merge entries — only merge concepts (done in Operation 2)
- Leave entries for human review.

## OPERATION 6: Write Summary

Write a compile report at 'Meta/Scripts/compile-report.md':
- Number of cross-links added
- Number of concepts merged
- Number of MoCs updated
- Number of potential duplicates found (not merged)
- Wiki index rebuilt: yes/no
- Timestamp

IMPORTANT:
- ALL MoC and Concept prose must be humanized before writing.
- Use [[wikilinks]] for all internal links.
- Do NOT modify files in 00-WIP/.
- Do NOT delete Entry notes — only Concept duplicates are auto-merged.
"

log "Running compile pass with agent..."
if run_with_retry "Wiki compile pass (v2)" "$prompt"; then
  log "=== Compile pass completed successfully (v2) ==="
else
  log "=== Compile pass FAILED (v2) ==="
  exit 1
fi
