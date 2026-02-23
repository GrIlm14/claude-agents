#!/bin/bash
# ============================================================
#  claude-agents v3 — Drop-in Multi-Agent Pipeline Setup
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-$(pwd)}"

if [[ "$(basename "$PROJECT_DIR")" == "claude-agents" ]]; then
    PROJECT_DIR="$(dirname "$PROJECT_DIR")"
fi

cd "$PROJECT_DIR"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   🤖 Claude Multi-Agent Pipeline Setup v3       ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║   Project: $(basename "$PROJECT_DIR")"
echo "║   Path:    $PROJECT_DIR"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Preflight ───────────────────────────────────────────────
MISSING=""
command -v tmux &>/dev/null || MISSING="$MISSING tmux"
command -v claude &>/dev/null || MISSING="$MISSING claude-code"

if [ -n "$MISSING" ]; then
    echo "❌ Missing:$MISSING"
    [[ "$MISSING" == *"tmux"* ]] && echo "   Fix: sudo apt install tmux"
    [[ "$MISSING" == *"claude-code"* ]] && echo "   Fix: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

# ── CLAUDE.md (shared protocol) ─────────────────────────────
mkdir -p .claude/prompts

if [ -f ".claude/CLAUDE.md" ]; then
    echo "⚠️  .claude/CLAUDE.md exists."
    read -rp "   Replace with v3 template? (y/n): " REPLACE
    if [[ "$REPLACE" =~ ^[Yy] ]]; then
        cp "$SCRIPT_DIR/templates/CLAUDE.md" .claude/CLAUDE.md
        echo "   ✅ Replaced"
    else
        echo "   Skipped"
    fi
else
    cp "$SCRIPT_DIR/templates/CLAUDE.md" .claude/CLAUDE.md
    echo "✅ Created .claude/CLAUDE.md"
fi

# ── Role prompt files ───────────────────────────────────────
echo ""
echo "📋 Installing role prompt files..."
for role_file in "$SCRIPT_DIR/templates/prompts/"*.md; do
    local_name=$(basename "$role_file")
    if [ ! -f ".claude/prompts/$local_name" ]; then
        cp "$role_file" ".claude/prompts/$local_name"
        echo "   ✅ Created .claude/prompts/$local_name"
    else
        echo "   ⏭️  .claude/prompts/$local_name exists — skipping"
    fi
done

# ── Control panel script ────────────────────────────────────
cp "$SCRIPT_DIR/scripts/control-panel.sh" .claude/control-panel.sh
chmod +x .claude/control-panel.sh
echo "✅ Installed .claude/control-panel.sh"

# ── pipeline.env ────────────────────────────────────────────
if [ ! -f "pipeline.env" ]; then
    cp "$SCRIPT_DIR/templates/pipeline.env" pipeline.env
    echo "✅ Created pipeline.env"
else
    echo "⏭️  pipeline.env exists — skipping"
fi

# ── .context/ structure ─────────────────────────────────────
mkdir -p .context/archive

declare -A CONTEXT_FILES=(
    ["status.md"]="IDLE"
    ["current-task.md"]="# Current Task\n\n_No active task._"
    ["implementation-log.md"]="# Implementation Log\n\n_Append-only._"
    ["test-results.md"]="# Test Results\n\n_Append-only._"
    ["decisions.md"]="# Architecture Decisions\n\n_Append-only._"
    ["security-review.md"]="# Security Review\n\n_Append-only._"
    ["docs-log.md"]="# Documentation Log\n\n_Append-only._"
    ["cycle-count.txt"]="0"
)

for file in "${!CONTEXT_FILES[@]}"; do
    if [ ! -f ".context/$file" ]; then
        echo -e "${CONTEXT_FILES[$file]}" > ".context/$file"
        echo "✅ Created .context/$file"
    else
        echo "⏭️  .context/$file exists"
    fi
done

# ── Pipeline CLI ────────────────────────────────────────────
cp "$SCRIPT_DIR/scripts/pipeline.sh" ./claude-pipeline
chmod +x ./claude-pipeline
echo "✅ Installed ./claude-pipeline"

# ── Summary ─────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   ✅ Setup Complete!                                  ║"
echo "╠═══════════════════════════════════════════════════════╣"
echo "║                                                       ║"
echo "║   Structure:                                          ║"
echo "║     .claude/CLAUDE.md           Shared protocol        ║"
echo "║     .claude/prompts/*.md        Role-specific prompts  ║"
echo "║     .claude/control-panel.sh    Control panel UI       ║"
echo "║     .context/                   Shared context files   ║"
echo "║     pipeline.env                Configuration          ║"
echo "║     claude-pipeline             CLI tool               ║"
echo "║                                                       ║"
echo "║   First steps:                                        ║"
echo "║     nano pipeline.env           Configure pipeline     ║"
echo "║     ./claude-pipeline doctor    Run preflight checks   ║"
echo "║     ./claude-pipeline auto      Launch everything      ║"
echo "║                                                       ║"
echo "║   Flags:                                              ║"
echo "║     --debug                     Verbose output         ║"
echo "║     --yolo                      Auto-accept all perms  ║"
echo "║                                                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
