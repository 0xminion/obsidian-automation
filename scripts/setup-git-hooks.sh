#!/usr/bin/env bash
# ============================================================================
# v2.1.0: Setup Git Hooks — Auto-commit after ingest and compile
# ============================================================================
# Installs git hooks in the vault repo for automatic version control.
# Creates post-operation commits with structured messages.
#
# Usage: VAULT_PATH="$HOME/MyVault" bash setup-git-hooks.sh
# ============================================================================

set -uo pipefail

VAULT_PATH="${VAULT_PATH:-$HOME/MyVault}"

# Optional: source common.sh if available for logging consistency
SCRIPT_DIR_SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR_SETUP/../lib/common.sh" ]; then
  source "$SCRIPT_DIR_SETUP/../lib/common.sh"
fi

if [ ! -d "$VAULT_PATH/.git" ]; then
  echo "Vault at $VAULT_PATH is not a git repository."
  echo "Initializing..."
  cd "$VAULT_PATH"
  git init
  echo "# Wiki Vault" > .gitignore
  echo ".DS_Store" >> .gitignore
  echo "*.tmp" >> .gitignore
  git add -A
  git commit -m "Initial vault commit" --quiet 2>/dev/null || true
fi

HOOKS_DIR="$VAULT_PATH/.git/hooks"
mkdir -p "$HOOKS_DIR"

# Pre-commit hook: ensure no 07-WIP files are staged
cat > "$HOOKS_DIR/pre-commit" << 'HOOK'
#!/usr/bin/env bash
# Prevent committing files from 07-WIP/
if git diff --cached --name-only | grep -q "^07-WIP/"; then
  echo "ERROR: Cannot commit files from 07-WIP/ — this is user territory."
  echo "Use 'git reset HEAD 07-WIP/' to unstage."
  exit 1
fi
HOOK
chmod +x "$HOOKS_DIR/pre-commit"

# Commit-msg hook: enforce structured format for wiki commits
cat > "$HOOKS_DIR/commit-msg" << 'HOOK'
#!/usr/bin/env bash
# Allow structured messages: "operation: description (date)"
# Also allow merge commits and reverts
msg=$(cat "$1")
if [[ ! "$msg" =~ ^(ingest|compile|query|lint|review|reindex|setup|Merge|Revert): ]] && [[ ! "$msg" =~ ^Initial ]]; then
  echo "Warning: commit message should follow 'operation: description (date)' format"
  echo "Got: $msg"
  # Don't block — just warn
fi
HOOK
chmod +x "$HOOKS_DIR/commit-msg"

echo "Git hooks installed in $HOOKS_DIR"
echo "  pre-commit: blocks 07-WIP/ commits"
echo "  commit-msg: warns on non-structured messages"

# Initial commit if there are uncommitted changes
cd "$VAULT_PATH"
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  git add -A
  git commit -m "setup: Install git hooks ($(date +%Y-%m-%d))" --quiet 2>/dev/null || true
  echo "Committed current state."
fi

echo "Done. Vault is now git-tracked with auto-commit support."
