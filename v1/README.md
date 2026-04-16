# ⚠️ DEPRECATED — v1

**Status:** Archived, no longer maintained  
**Replaced by:** v2.2 (root scripts/, lib/, prompts/)

This directory contains the original v1 implementation kept for reference only.

**Do not use v1 scripts in production.** Use the v2.2 scripts in the root `scripts/` directory instead.

## What moved to v2.2:

| v1 Location | v2.2 Location |
|-------------|---------------|
| `v1/scripts/process-inbox.sh` | `scripts/process-inbox.sh` |
| `v1/scripts/extract-transcript.sh` | `scripts/extract-transcript.sh` |
| `v1/skills/transcript-extraction.md` | `skills/transcript-extraction.md` |
| `v1/skills/transcriptapi.md` | `skills/transcriptapi.md` |

## Key differences in v2.2:
- Shared library (`lib/common.sh`) — no code duplication
- Externalized prompts (`prompts/*.prompt`)
- Proper lock management with PID-based stale detection
- Full transcript extraction fallback chains
- Post-ingest auto-updates (dashboard, tag-registry, wiki-index)
- Typed edges, domain-adaptive templates, schema co-evolution

---

*Archived: 2026-04-16*
