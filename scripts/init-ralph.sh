#!/bin/bash
# Ralph Wiggum: Initialize Ralph in a project
# Run this to set up Ralph tracking in your project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "⚠️  Warning: Not in a git repository."
  echo "   Ralph works best with git for checkpoint tracking."
  echo ""
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Create .ralph directory
mkdir -p .ralph

# Check if RALPH_TASK.md exists
if [[ ! -f "RALPH_TASK.md" ]]; then
  echo "📝 Creating RALPH_TASK.md template..."
  cp "$SKILL_DIR/assets/RALPH_TASK_TEMPLATE.md" RALPH_TASK.md
  echo "   Edit RALPH_TASK.md to define your task."
else
  echo "✓ RALPH_TASK.md already exists"
fi

# Initialize state files
echo "📁 Initializing .ralph/ directory..."

cat > .ralph/state.md <<EOF
---
iteration: 0
status: initialized
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---

# Ralph State

Ready to begin. Start a conversation and mention the Ralph task.
EOF

cat > .ralph/guardrails.md <<EOF
# Ralph Guardrails (Signs)

These are lessons learned from iterations. Follow these to avoid known pitfalls.

## Core Signs

### Sign: Read Before Writing
- **Always** read existing files before modifying them
- Check git history for context on why things are the way they are

### Sign: Test After Changes
- Run tests after every significant change
- Don't assume code works - verify it

### Sign: Commit Checkpoints
- Commit working states before attempting risky changes
- Use descriptive commit messages

### Sign: One Thing at a Time
- Focus on one criterion at a time
- Don't try to do everything in one iteration

---

## Learned Signs

(Signs added from observed failures will appear below)

EOF

cat > .ralph/context-log.md <<EOF
# Context Allocation Log

Tracking what's been loaded into context to prevent redlining.

## Current Session

| File | Size (est tokens) | Timestamp |
|------|-------------------|-----------|

## Estimated Context Usage

- Allocated: 0 tokens
- Threshold: 80000 tokens (warn at 80%)
- Status: 🟢 Healthy

EOF

cat > .ralph/failures.md <<EOF
# Failure Log

Tracking failure patterns to detect "gutter" situations.

## Recent Failures

(Failures will be logged here)

## Pattern Detection

- Repeated failures: 0
- Gutter risk: Low

EOF

cat > .ralph/progress.md <<EOF
# Progress Log

## Summary

- Iterations completed: 0
- Tasks completed: 0
- Current status: Initialized

## Iteration History

(Progress will be logged here as iterations complete)

EOF

# Add .ralph to .gitignore if not already there
if [[ -f ".gitignore" ]]; then
  if ! grep -q "^\.ralph/" .gitignore; then
    echo "" >> .gitignore
    echo "# Ralph state (regenerated each session)" >> .gitignore
    echo ".ralph/" >> .gitignore
    echo "✓ Added .ralph/ to .gitignore"
  fi
else
  echo "# Ralph state (regenerated each session)" > .gitignore
  echo ".ralph/" >> .gitignore
  echo "✓ Created .gitignore with .ralph/"
fi

# Copy hooks.json to .cursor if it exists
if [[ -d ".cursor" ]] || mkdir -p .cursor; then
  cp "$SKILL_DIR/hooks.json" .cursor/hooks.json
  echo "✓ Installed hooks to .cursor/hooks.json"
  
  # Copy scripts
  mkdir -p .cursor/ralph-scripts
  cp "$SKILL_DIR/scripts/"*.sh .cursor/ralph-scripts/
  chmod +x .cursor/ralph-scripts/*.sh
  
  # Update hooks.json to point to local scripts
  sed -i 's|./scripts/|./.cursor/ralph-scripts/|g' .cursor/hooks.json
  echo "✓ Installed Ralph scripts to .cursor/ralph-scripts/"
fi

echo ""
echo "✅ Ralph initialized!"
echo ""
echo "Next steps:"
echo "  1. Edit RALPH_TASK.md to define your task"
echo "  2. Start a new Cursor conversation"
echo "  3. Tell Cursor to work on the Ralph task"
echo ""
echo "Ralph will:"
echo "  - Track iterations in .ralph/"
echo "  - Add guardrails based on failures"
echo "  - Monitor context health"
echo "  - Suggest fresh starts when needed"
echo ""
echo "Learn more: https://ghuntley.com/ralph/"
