#!/bin/bash
# Ralph Wiggum: Initialize Ralph in a project
# Sets up Ralph tracking for CLI mode with Beads task tracking

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# =============================================================================
# FLAG PARSING
# =============================================================================

PRINT_TEMPLATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-template)
      PRINT_TEMPLATE=true
      shift
      ;;
    -h|--help)
      cat << 'EOF'
Ralph Wiggum: Initialize Ralph in a project

Usage:
  ./init-ralph.sh              # Initialize Ralph state files
  ./init-ralph.sh --print-template  # Print task template to stdout

Options:
  --print-template   Print the task file template to stdout (for BYO plan docs)
  -h, --help         Show this help

Examples:
  # Initialize Ralph in current directory
  ./init-ralph.sh

  # Create a new task file from template
  ./init-ralph.sh --print-template > plans/my-task.md

  # Or pipe to clipboard
  ./init-ralph.sh --print-template | pbcopy
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use -h for help."
      exit 1
      ;;
  esac
done

# =============================================================================
# PRINT TEMPLATE MODE (non-invasive)
# =============================================================================

if [[ "$PRINT_TEMPLATE" == "true" ]]; then
  if [[ -f "$SKILL_DIR/assets/RALPH_TASK_TEMPLATE.md" ]]; then
    cat "$SKILL_DIR/assets/RALPH_TASK_TEMPLATE.md"
  else
    cat << 'EOF'
---
task: [Brief description of the task]
test_command: "npm test"
---

# Task: [Task Name]

## Overview

[Describe what needs to be built/fixed/improved]

## Requirements

### Functional Requirements

1. [Requirement 1]
2. [Requirement 2]
3. [Requirement 3]

### Non-Functional Requirements

- [Performance, security, etc.]

## Constraints

- [Technology constraints]
- [Time constraints]
- [Other limitations]

## Success Criteria

The following will be converted to Beads tasks when Ralph first runs.
Progress is tracked via `bd ready`, `bd close`, etc.

1. [Verifiable criterion 1]
2. [Verifiable criterion 2]
3. [Verifiable criterion 3]

## Notes

[Any additional context, links to documentation, etc.]

---

## Ralph Instructions

When working on this task:

1. Check `bd ready --label ralph:<runId> --json` to find the next available task
2. Claim it: `bd update <id> --status in_progress --json`
3. Work on the task
4. Close when done: `bd close <id> --reason "description" --json`
5. Sync: `bd sync`
6. Read `.ralph/runs/<runId>/progress.md` to see what's been done
7. Check `.ralph/guardrails.md` for signs to follow
8. Update `.ralph/runs/<runId>/progress.md` with your progress
9. Commit your changes with descriptive messages
10. When all tasks are closed, output: `<ralph>COMPLETE</ralph>`
11. If stuck on the same issue 3+ times, output: `<ralph>GUTTER</ralph>`
EOF
  fi
  exit 0
fi

# =============================================================================
# INITIALIZATION MODE
# =============================================================================

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
  # Add RALPH_TASK.md as a local default plan doc (not versioned by default)
  if ! grep -q "^RALPH_TASK.md$" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Ralph default task file (local plan doc - use --task-file for versioned plans)" >> .gitignore
    echo "RALPH_TASK.md" >> .gitignore
  fi
  echo "✓ Updated .gitignore"
else
  cat > .gitignore << 'EOF'
# Ralph config (may contain API keys)
.cursor/ralph-config.json

# Ralph default task file (local plan doc - use --task-file for versioned plans)
RALPH_TASK.md
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
echo "  • .ralph/guardrails.md    - Lessons learned (shared across runs)"
echo "  • .cursor/ralph-scripts/  - Ralph scripts"
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
  echo "  2. Create a task/plan file (see template below)"
  echo "  3. Run: ./.cursor/ralph-scripts/ralph-setup.sh --task-file <your-plan.md>"
else
  echo "  1. Create a task/plan file (any path, e.g. plans/api.md)"
  echo "  2. Run: ./.cursor/ralph-scripts/ralph-setup.sh --task-file <your-plan.md>"
fi
echo ""
echo "Get the task template:"
echo "  ./.cursor/ralph-scripts/init-ralph.sh --print-template > plans/my-task.md"
echo ""
echo "Fallback: If RALPH_TASK.md exists, you can omit --task-file."
echo ""
echo "Examples:"
echo "  # Single task"
echo "  ./.cursor/ralph-scripts/ralph-setup.sh --task-file plans/api.md"
echo ""
echo "  # Parallel runs (different task files)"
echo "  ./.cursor/ralph-scripts/ralph-loop.sh --task-file plans/api.md --run-id api"
echo "  ./.cursor/ralph-scripts/ralph-loop.sh --task-file plans/ui.md --run-id ui"
echo ""
echo "Monitor progress:"
echo "  bd list --json                                # See all Beads tasks"
echo "  tail -f .ralph/runs/<runId>/activity.log     # Real-time logs"
echo ""
echo "Learn more:"
echo "  Ralph: https://ghuntley.com/ralph/"
echo "  Beads: https://github.com/steveyegge/beads"
echo "═══════════════════════════════════════════════════════════════════"
