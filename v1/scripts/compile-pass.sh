#!/usr/bin/env bash
# ============================================================================
# Compile Pass — Incremental wiki improvement
# ============================================================================
# Scans the existing vault (Distilled, Atomic, MoCs) and performs a
# "re-compilation" to improve the wiki over time. Inspired by Karpathy's
# concept of incremental compilation rather than one-shot processing.
#
# What this does:
# 1. Cross-links: finds Atomic/Distilled notes that reference the same
#    Source or share tags, and adds missing wikilinks between them.
# 2. MoC refresh: rebuilds MoC notes with updated summaries from linked notes.
# 3. Duplicate detection: finds Atomically similar notes and suggests merges.
# 4. Orphaned note detection: finds notes with zero backlinks.
# ============================================================================

set -uo pipefail

VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"
LOG_FILE="$VAULT_PATH/Meta/Scripts/processing.log"
LOCK_FILE="/tmp/obsidian-compile-pass-$(echo "$VAULT_PATH" | md5sum | cut -c1-8).lock"

# Agent command
AGENT_CMD="${AGENT_CMD:-claude -p}"

# Prevent overlapping runs
if [ -f "$LOCK_FILE" ]; then
  echo "$(date): Compile pass already running. Exiting." >> "$LOG_FILE"
  exit 0
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

log() { echo "$(date): $1" >> "$LOG_FILE"; }
log "=== Starting compile pass ==="

# Count notes for reporting
distilled_count=$(find "$VAULT_PATH/02-Distilled" -name '*.md' 2>/dev/null | wc -l)
atomic_count=$(find "$VAULT_PATH/03-Atomic" -name '*.md' 2>/dev/null | wc -l)
moc_count=$(find "$VAULT_PATH/04-MoCs" -name '*.md' 2>/dev/null | wc -l)

log "Vault snapshot: $distilled_count distilled, $atomic_count atomic, $moc_count MoCs"

# Build the compile pass prompt
prompt="
VAULT LOCATION: $VAULT_PATH
VAULT SNAPSHOT: $distilled_count Distilled notes, $atomic_count Atomic notes, $moc_count MoCs.

TASK: Perform a wiki compile pass — an incremental improvement of the knowledge base.

You are improving an existing Obsidian vault. You must NOT re-process the inbox.
You are working with notes that already exist in 02-Distilled/, 03-Atomic/, and 04-MoCs/.

Perform these operations in order:

## OPERATION 1: Cross-link analysis

Scan all Distilled and Atomic notes. Find notes that:
- Reference the same Source note (check source: frontmatter)
- Share tags (run 'obsidian tags sort=count counts' to see tag usage)
- Mention related concepts by scanning headings and first paragraphs

For each pair of related notes that don't already link to each other,
add a wikilink in the 'Linked concepts' section (Distilled) or
'References' section (Atomic). Use 'obsidian search' to verify that
the link target doesn't already exist in the note.

## OPERATION 2: MoC Rebuild

For each existing MoC in 04-MoCs/:
1. Find all Atomic and Distilled notes that are tagged with the MoC's topic
   or mention it in their content.
2. Rebuild the MoC with this structure:

# <Topic Name> — Map of Content

## Overview
<2-3 sentence synthesized summary of this topic. What does it cover?
Why does it matter? Pull synthesized understanding from the notes.>

## Core Concepts
- [[<Atomic note>]] — <1-sentence summary>

## Related Research
- [[<Distilled note>]] — <1-sentence summary>

## Open Threads
- <Unanswered questions or gaps across the linked notes>

3. Run the Humanizer skill before writing the MoC.

## OPERATION 3: Duplicate Detection

Find Atomic notes that:
- Have very similar titles (fuzzy match or shared key terms)
- Cover the same idea (similar body content)

For duplicates found:
- Create a report file at 'Meta/Scripts/duplicate-report.md' listing
  pairs of potentially duplicate Atomic notes with their paths.
- DO NOT auto-merge — leave this for human review.

## OPERATION 4: Output Summary

Write a summary at 'Meta/Scripts/compile-report.md':
- Number of cross-links added
- Number of MoCs updated
- Number of potential duplicates found
- Timestamp

IMPORTANT:
- ALL MoC prose must be humanized before writing.
- Use [[wikilinks]] for all internal links.
- Do NOT modify files in 00-Inbox/quick notes/ or 05-WIP/.
"

log "Running compile pass with agent..."
if cd "$VAULT_PATH" && $AGENT_CMD "$prompt" 2>> "$LOG_FILE"; then
  log "=== Compile pass completed successfully ==="
else
  log "=== Compile pass FAILED ==="
  exit 1
fi
