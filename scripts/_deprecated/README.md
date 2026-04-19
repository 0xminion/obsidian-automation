# Deprecated Scripts

These scripts are superseded by the Python pipeline (`pipeline/cli.py`).
They are kept for reference only — DO NOT USE.

| Deprecated Script | Python Replacement |
|---|---|
| process-inbox.sh | `pipeline ingest` (pipeline/cli.py) |
| stage1-extract.sh | `pipeline/extract.py:extract_all()` |
| stage2-plan.sh | `pipeline/plan.py:plan_sources()` |
| stage3-create.sh | `pipeline/create.py:create_all()` |
| build_batch_prompt.py | `pipeline/create.py:build_batch_prompt()` |
| reindex.sh | `pipeline reindex` (pipeline/vault.py:reindex()) |

## Migration

```bash
# Old way:
cd ~/MyVault && bash Meta/Scripts/process-inbox.sh

# New way:
cd ~/MyVault && ./run.sh
# or:
pipeline ingest ~/MyVault
```
