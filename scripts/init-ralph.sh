#!/bin/bash
# Ralph Wiggum: Initialize Ralph in a project
# Sets up Ralph tracking for CLI mode with Beads task tracking

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

echo "═══════════════════════════════════════════════════════════════════"
echo "🐛 Ralph Wiggum Initialization"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Track missing dependencies
BEADS_MISSING=false

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "⚠️  Warning: Not in a git repository."
  echo "   Ralph works best with git for state persistence."
  echo ""
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Check for cursor-agent CLI
if ! command -v cursor-agent &> /dev/null; then
  echo "⚠️  Warning: cursor-agent CLI not found."
  echo "   Install via: curl https://cursor.com/install -fsS | bash"
  echo ""
fi

# =============================================================================
# CHECK FOR BEADS (REQUIRED)
# =============================================================================

if ! command -v bd &> /dev/null; then
  BEADS_MISSING=true
  echo "❌ bd (Beads) CLI not found - REQUIRED"
  echo ""
  echo "   Ralph uses Beads for task tracking. Install via one of:"
  echo ""
  echo "   # Option 1: curl installer (recommended)"
  echo "   curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash"
  echo ""
  echo "   # Option 2: Homebrew (macOS/Linux)"
  echo "   brew install steveyegge/beads/bd"
  echo ""
  echo "   # Option 3: npm"
  echo "   npm install -g @beads/bd"
  echo ""
  echo "   After installing, run: bd init --stealth --quiet"
  echo ""
else
  echo "✓ bd (Beads) CLI found"
  
  # Initialize Beads in stealth mode if not already initialized
  if ! bd info --json &>/dev/null 2>&1; then
    echo "📦 Initializing Beads in stealth mode..."
    if bd init --stealth --quiet 2>/dev/null; then
      echo "✓ Beads initialized (stealth mode - no repo commits)"
    else
      echo "⚠️  Could not initialize Beads automatically."
      echo "   Run manually: bd init --stealth --quiet"
    fi
  else
    echo "✓ Beads already initialized"
  fi
fi
echo ""

# Create directories
mkdir -p .ralph
mkdir -p .cursor/ralph-scripts

# =============================================================================
# CREATE RALPH_TASK.md IF NOT EXISTS
# =============================================================================

if [[ ! -f "RALPH_TASK.md" ]]; then
  echo "📝 Creating RALPH_TASK.md template..."
  if [[ -f "$SKILL_DIR/assets/RALPH_TASK_TEMPLATE.md" ]]; then
    cp "$SKILL_DIR/assets/RALPH_TASK_TEMPLATE.md" RALPH_TASK.md
  else
    cat > RALPH_TASK.md << 'EOF'
---
task: Your task description here
test_command: "npm test"
---

# Task

Describe what you want to accomplish.

## Success Criteria

The following will be converted to Beads tasks when you first run Ralph:

1. First thing to complete
2. Second thing to complete
3. Third thing to complete

## Context

Any additional context the agent should know.

## Notes

- This task file defines the work to be done
- When Ralph runs, it creates Beads issues from Success Criteria
- Progress is tracked via Beads (`bd list`, `bd ready`, etc.)
- Each run gets isolated state in `.ralph/runs/<runId>/`
EOF
  fi
  echo "   Edit RALPH_TASK.md to define your task."
else
  echo "✓ RALPH_TASK.md already exists"
fi

# =============================================================================
# INITIALIZE STATE FILES (shared guardrails only)
# =============================================================================

echo "📁 Initializing .ralph/ directory..."

# Only create guardrails.md at the top level (shared across runs)
# Per-run state is created in .ralph/runs/<runId>/ on first run
if [[ ! -f ".ralph/guardrails.md" ]]; then
  cat > .ralph/guardrails.md << 'EOF'
# Ralph Guardrails (Signs)

> Lessons learned from past failures. READ THESE BEFORE ACTING.

## Core Signs

### Sign: Read Before Writing
- **Trigger**: Before modifying any file
- **Instruction**: Always read the existing file first
- **Added after**: Core principle

### Sign: Test After Changes
- **Trigger**: After any code change
- **Instruction**: Run tests to verify nothing broke
- **Added after**: Core principle

### Sign: Commit Checkpoints
- **Trigger**: Before risky changes
- **Instruction**: Commit current working state first
- **Added after**: Core principle

---

## Learned Signs

(Signs added from observed failures will appear below)

EOF
fi

echo "✓ .ralph/ initialized"

# =============================================================================
# INSTALL SCRIPTS
# =============================================================================

echo "📦 Installing scripts..."

# Copy scripts
cp "$SKILL_DIR/scripts/"*.sh .cursor/ralph-scripts/ 2>/dev/null || true
chmod +x .cursor/ralph-scripts/*.sh 2>/dev/null || true

echo "✓ Scripts installed to .cursor/ralph-scripts/"

# =============================================================================
# UPDATE .gitignore
# =============================================================================

if [[ -f ".gitignore" ]]; then
  # Don't gitignore .ralph/ - we want it tracked for state persistence
  if ! grep -q "ralph-config.json" .gitignore; then
    echo "" >> .gitignore
    echo "# Ralph config (may contain API keys)" >> .gitignore
    echo ".cursor/ralph-config.json" >> .gitignore
  fi
  echo "✓ Updated .gitignore"
else
  cat > .gitignore << 'EOF'
# Ralph config (may contain API keys)
.cursor/ralph-config.json
EOF
  echo "✓ Created .gitignore"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if [[ "$BEADS_MISSING" == "true" ]]; then
  echo "⚠️  Ralph initialized (with warnings)"
else
  echo "✅ Ralph initialized!"
fi
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [[ "$BEADS_MISSING" == "true" ]]; then
  echo "⚠️  IMPORTANT: Beads (bd) is required but not installed!"
  echo ""
  echo "   Install Beads first:"
  echo "   curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash"
  echo ""
  echo "   Then initialize: bd init --stealth --quiet"
  echo ""
fi

echo "Files created:"
echo "  • RALPH_TASK.md           - Define your task here"
echo "  • .ralph/guardrails.md    - Lessons learned (shared across runs)"
echo ""
echo "Per-run files (created on first run):"
echo "  • .ralph/runs/<runId>/progress.md    - Progress log"
echo "  • .ralph/runs/<runId>/activity.log   - Tool call log"
echo "  • .ralph/runs/<runId>/errors.log     - Failure log"
echo "  • .ralph/runs/<runId>/beads.label    - Beads label"
echo "  • .ralph/runs/<runId>/beads.root_id  - Root epic ID"
echo ""
echo "Next steps:"
if [[ "$BEADS_MISSING" == "true" ]]; then
  echo "  1. Install Beads (see above)"
  echo "  2. Edit RALPH_TASK.md to define your task and criteria"
  echo "  3. Run: ./.cursor/ralph-scripts/ralph-setup.sh"
else
  echo "  1. Edit RALPH_TASK.md to define your task and criteria"
  echo "  2. Run: ./.cursor/ralph-scripts/ralph-setup.sh"
fi
echo ""
echo "Parallel runs (different task files):"
echo "  ./.cursor/ralph-scripts/ralph-loop.sh --task-file TASK_A.md --run-id a"
echo "  ./.cursor/ralph-scripts/ralph-loop.sh --task-file TASK_B.md --run-id b"
echo ""
echo "Monitor progress:"
echo "  bd list --json                                # See all Beads tasks"
echo "  tail -f .ralph/runs/<runId>/activity.log     # Real-time logs"
echo ""
echo "Learn more:"
echo "  Ralph: https://ghuntley.com/ralph/"
echo "  Beads: https://github.com/steveyegge/beads"
echo "═══════════════════════════════════════════════════════════════════"
