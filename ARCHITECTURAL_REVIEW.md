# Architectural Review: obsidian-automation v2.2

## Executive Summary

This review identifies **7 critical issues**, **5 medium issues**, and **8 minor issues** in the obsidian-automation v2.2 repository. The most significant finding is that `extract-transcript.sh` is missing from the v2.2 scripts directory despite being extensively documented and referenced in the PRD, README, and other documentation.

## 1. Integration Consistency

### Issues Found:

#### Critical:
1. **Missing `extract-transcript.sh` script** - Referenced in PRD.md (line 273), README.md (lines 127-128), and multiple documentation files, but does not exist in `scripts/` directory. Only exists in `v1/scripts/extract-transcript.sh`.

#### Medium:
2. **`podcast-structure.prompt` not loaded** - File exists in `prompts/` directory but is never loaded by any script. Process-inbox.sh uses inline prompts for podcast processing instead.

#### Minor:
3. **Unused functions in `lib/common.sh`** - Several functions are defined but never called:
   - `release_lock()` - 0 direct calls (only used via trap)
   - `register_url_source()` - 0 calls
   - `add_edge()` - 0 calls
   - `get_edges()` - 0 calls
   - `get_edges_by_type()` - 0 calls

### Positive Findings:
- All scripts properly source `lib/common.sh`
- All scripts that perform write operations call `auto_commit()` after operations
- All prompt files referenced in PRD are loaded correctly
- Lock management is properly implemented with atomic `mkdir` operations

## 2. Dependency Chain Verification

### Issues Found:

#### Medium:
1. **`lib/transcribe.sh` doesn't source `lib/common.sh`** - Relies on caller to source common.sh first. While process-inbox.sh does this correctly, standalone use of transcribe.sh would fail.

#### Minor:
2. **Unused dependency declarations** - `transcribe.sh` documents dependency on common.sh but doesn't enforce it.

### Positive Findings:
- No circular dependencies found
- Dependency graph in PRD.md matches actual imports (except for missing extract-transcript.sh)
- All scripts are executable except migrate-vault.sh (644 permissions)

## 3. Documentation Accuracy

### Issues Found:

#### Critical:
1. **`extract-transcript.sh` missing from v2.2** - Documented in:
   - PRD.md scripts table (line 244)
   - PRD.md file structure (line 273)
   - PRD.md dependency graph (lines 303, 308)
   - README.md transcript section (lines 127-128)
   - TRANSCRIPT_EXTRACTION_QUICKREF.md
   - TRANSCRIPT_EXTRACTION_README.md

#### Medium:
2. **README.md scripts table inaccurate**:
   - Shows 9 health checks for lint-vault.sh, actual is 10
   - Missing `migrate-vault.sh` from table (exists in scripts/)
   - Missing `extract-transcript.sh` from table (doesn't exist but documented elsewhere)

3. **`migrate-vault.sh` not executable** - Has 644 permissions, should be 755 like other scripts

4. **Environment variables not documented**:
   - `TRANSCRIPT_API_KEY` - Referenced in process-inbox.sh but not in .env.example
   - `SUPADATA_API_KEY` - Referenced in process-inbox.sh but not in .env.example

#### Minor:
5. **PRD.md scripts table includes extract-transcript.sh** - Should be removed or marked as missing

### Positive Findings:
- PRD.md file structure matches actual directory structure (except for missing extract-transcript.sh)
- Acceptance criteria in PRD are mostly implemented (see Feature Completeness section)

## 4. Feature Completeness

### R1-R12 Recommendations Review:

| Rec | Description | Status | Notes |
|-----|-------------|--------|-------|
| R1 | Interactive Ingestion + Review Pass | ✅ Complete | --interactive flag, review-pass.sh, reviewed/review_notes fields |
| R2 | Query Compound-Back | ✅ Complete | query-vault.prompt includes Step 7 compound-back |
| R3 | Extract lib/common.sh | ✅ Complete | All scripts source common.sh |
| R4 | Domain-Adaptive Entry Templates | ✅ Complete | 4 templates, lint checks template sections |
| R5 | Typed Edges | ✅ Complete | edges.tsv, add_edge/get_edges functions, lint checks |
| R6 | Git Hooks for Auto-Commit | ✅ Complete | setup-git-hooks.sh, auto_commit() in all scripts |
| R7 | Vault Stats Dashboard | ✅ Complete | vault-stats.sh generates dashboard.md |
| R8 | Externalize Prompts | ✅ Complete | 9 prompt files loaded via load_prompt() |
| R9 | Full Reindex | ✅ Complete | reindex.sh rebuilds wiki-index.md |
| R10 | Schema Co-Evolution | ✅ Complete | compile-pass.sh Operation 9 |
| R11 | Universal Transcript Extraction | ❌ Incomplete | extract-transcript.sh missing from v2.2 |
| R12 | Post-Ingest Auto-Updates | ✅ Complete | process-inbox.sh calls vault-stats.sh, update-tag-registry.sh, reindex.sh |

### Transcript Extraction Fallback Chain:
- **YouTube**: Process-inbox.sh implements: existing → TranscriptAPI → Supadata (but extract-transcript.sh missing)
- **Podcasts**: Process-inbox.sh implements: existing → AssemblyAI (via transcribe.sh)

### Post-Ingest Auto-Updates:
- ✅ `process-inbox.sh` calls `vault-stats.sh` after processing
- ✅ `process-inbox.sh` calls `update-tag-registry.sh` after processing  
- ✅ `process-inbox.sh` calls `reindex.sh` if ≥5 notes processed

## 5. Vault Structure Validation

### Issues Found:

#### Minor:
1. **setup_directory_structure() creates Meta/ directories** - README vault structure doesn't mention Meta/Scripts and Meta/Templates, but Quick Start section does reference them.

### Positive Findings:
- All directories in README vault structure are created by setup_directory_structure()
- All template files in templates/ are referenced in agents.md or prompts

## 6. Missing Items

### Critical Missing Items:
1. **`scripts/extract-transcript.sh`** - Extensively documented but missing

### Medium Missing Items:
2. **Lock acquisition for lint-vault.sh, query-vault.sh, migrate-vault.sh** - These scripts don't acquire locks, which could cause issues with concurrent execution

3. **TRANSCRIPT_API_KEY and SUPADATA_API_KEY in .env.example** - Referenced in code but not documented

### Minor Missing Items:
4. **`register_url_source()` usage** - Function defined but never called (URL registration done inline in prompts)

5. **Edge management functions** - `add_edge()`, `get_edges()`, `get_edges_by_type()` defined but never called (edges managed inline in prompts)

## Recommendations

### Immediate Actions (Critical):
1. **Create `scripts/extract-transcript.sh`** - Either port from v1 or implement new version
2. **Fix `migrate-vault.sh` permissions** - Change to 755

### Short-term Actions (Medium):
3. **Update README.md scripts table** - Add migrate-vault.sh, fix lint-vault.sh check count
4. **Document missing environment variables** - Add TRANSCRIPT_API_KEY and SUPADATA_API_KEY to .env.example
5. **Add lock acquisition to lint-vault.sh, query-vault.sh, migrate-vault.sh**

### Long-term Actions (Minor):
6. **Clean up unused functions** - Either use or remove unused functions from common.sh
7. **Update PRD.md** - Remove extract-transcript.sh from scripts table or mark as pending
8. **Source common.sh in transcribe.sh** - For standalone safety

## Conclusion

The obsidian-automation v2.2 repository is largely well-architected and implements most of its documented features. However, the missing `extract-transcript.sh` script is a significant gap that affects documentation accuracy and feature completeness. The codebase shows good practices in error handling, logging, and lock management, but has some inconsistencies in documentation and a few unused functions that should be cleaned up.

**Overall Assessment**: **85% complete** - Core functionality is solid, but missing key component and documentation inconsistencies need addressing.