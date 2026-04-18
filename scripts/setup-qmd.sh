#!/usr/bin/env bash
# ============================================================================
# setup-qmd.sh — Initialize qmd for semantic concept search
# ============================================================================
# Installs qmd (if not present), configures Qwen3-Embedding-0.6B-Q8,
# indexes the concepts collection, and runs initial embedding.
#
# Usage: ./setup-qmd.sh [--vault PATH]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

echo "╔══════════════════════════════════════════════╗"
echo "║  QMD Setup — Semantic Concept Search         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ═══════════════════════════════════════════════════════════
# STEP 1: Check/install qmd
# ═══════════════════════════════════════════════════════════

if command -v qmd &>/dev/null; then
  echo "✓ qmd already installed: $(qmd --version 2>/dev/null || echo 'unknown')"
else
  echo "Installing qmd via npm..."
  npm install -g @tobilu/qmd 2>&1 | tail -3
  if command -v qmd &>/dev/null; then
    echo "✓ qmd installed: $(qmd --version 2>/dev/null)"
  else
    echo "ERROR: Failed to install qmd. Ensure Node.js >= 22 is installed."
    exit 1
  fi
fi

# ═══════════════════════════════════════════════════════════
# STEP 2: Configure embedding model
# ═══════════════════════════════════════════════════════════

echo ""
echo "Configuring Qwen3-Embedding-0.6B-Q8 model..."
mkdir -p ~/.config/qmd

if [ -f ~/.config/qmd/index.yml ] && grep -q "Qwen3-Embedding-0.6B" ~/.config/qmd/index.yml 2>/dev/null; then
  echo "✓ Model already configured"
else
  cat > ~/.config/qmd/index.yml << 'EOF'
models:
  embed: "hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf"
EOF
  echo "✓ Model config written to ~/.config/qmd/index.yml"
fi

# ═══════════════════════════════════════════════════════════
# STEP 3: Index concepts collection
# ═══════════════════════════════════════════════════════════

CONCEPTS_DIR="${VAULT_PATH}/04-Wiki/concepts"

if [ ! -d "$CONCEPTS_DIR" ]; then
  echo "ERROR: Concepts directory not found: $CONCEPTS_DIR"
  exit 1
fi

concept_count=$(find "$CONCEPTS_DIR" -name "*.md" | wc -l)
echo ""
echo "Indexing $concept_count concept files from: $CONCEPTS_DIR"

# Check if already indexed
if qmd status 2>/dev/null | grep -q "concepts"; then
  echo "Collection 'concepts' already exists, updating..."
  qmd update 2>&1 | grep -E "^(Indexed|Collection|✓)" || true
else
  qmd collection add "$CONCEPTS_DIR" --name concepts --mask '**/*.md' 2>&1 | grep -E "^(Indexed|Collection|Creating|✓)" || true
fi

# ═══════════════════════════════════════════════════════════
# STEP 4: Generate embeddings
# ═══════════════════════════════════════════════════════════

echo ""
echo "Generating embeddings (this may take a few minutes on CPU)..."

# Suppress Vulkan build warnings
qmd embed -f 2>&1 | grep -v "cmake\|CMAKE\|Vulkan\|vulkan\|node-llama-cpp\|Cloning\|NOT searching\|C compiler\|Check for working\|Detecting\|Found\|Including\|Adding\|Performing\|Configuring" | tail -5

# ═══════════════════════════════════════════════════════════
# STEP 5: Verify
# ═══════════════════════════════════════════════════════════

echo ""
echo "━━━ Verification ━━━"
qmd status 2>&1 | grep -E "(Documents|Vectors|Collection|Embedding)" | head -10

echo ""
echo "Test query (semantic search):"
qmd query "prediction markets" --json -n 3 --min-score 0.3 -c concepts --no-rerank 2>&1 | \
  python3 -c "
import json, sys
try:
    results = json.load(sys.stdin)
    for r in results:
        f = r.get('file','').split('/')[-1].replace('.md','')
        s = r.get('score', 0)
        print(f'  {s:.2f}  {f}')
    print(f'\n✓ {len(results)} semantic matches found')
except:
    print('  (query test skipped — first run may need model download)')
" 2>/dev/null || echo "  (query test failed — models may need to download on first use)"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  QMD Setup Complete                          ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Model:   Qwen3-Embedding-0.6B-Q8 (639MB)   ║"
echo "║  Concepts: $concept_count files indexed       ║"
echo "║  Search:  qmd query '<text>' -c concepts     ║"
echo "╚══════════════════════════════════════════════╝"
