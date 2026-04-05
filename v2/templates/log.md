# Wiki Activity Log

Chronological record of all operations on the knowledge base.
Use `grep "^## \[" log.md | tail -N` to see the last N operations.

---

## Log Entry Format

Each entry starts with a consistent heading:
- `## [YYYY-MM-DD] ingest | Source Title`
- `## [YYYY-MM-DD] compile | Description`
- `## [YYYY-MM-DD] query | "Question?"`
- `## [YYYY-MM-DD] lint | Description`

Within each entry, list what was created, updated, or merged.
The LLM reads this to understand recent history and avoid redundant work.

---
