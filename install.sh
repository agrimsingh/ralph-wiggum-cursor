#!/bin/bash
# Ralph Wiggum: One-click installer
# Usage: curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main/install.sh | bash

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main"

echo "═══════════════════════════════════════════════════════════════════"
echo "🐛 Ralph Wiggum Installer"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Track if we have critical missing dependencies
BEADS_MISSING=false

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "⚠️  Warning: Not in a git repository."
  echo "   Ralph works best with git for state persistence."
  echo ""
  echo "   Run: git init"
  echo ""
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
  echo "   Learn more: https://github.com/steveyegge/beads"
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
  echo ""
fi

# Check for gum and offer to install
if ! command -v gum &> /dev/null; then
  echo "📦 gum not found (provides beautiful CLI menus)"
  
  # Auto-install if INSTALL_GUM=1 or prompt user
  SHOULD_INSTALL=""
  if [[ "${INSTALL_GUM:-}" == "1" ]]; then
    SHOULD_INSTALL="y"
  else
    read -p "   Install gum? [y/N] " -n 1 -r < /dev/tty
    echo
    SHOULD_INSTALL="$REPLY"
  fi
  
  if [[ "$SHOULD_INSTALL" =~ ^[Yy]$ ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      if command -v brew &> /dev/null; then
        echo "   Installing via Homebrew..."
        brew install gum
      else
        echo "   ⚠️  Homebrew not found. Install manually: brew install gum"
      fi
    elif [[ -f /etc/debian_version ]]; then
      echo "   Installing via apt..."
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
      echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
      sudo apt update && sudo apt install -y gum
    elif [[ -f /etc/fedora-release ]] || [[ -f /etc/redhat-release ]]; then
      echo "   Installing via dnf..."
      echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo
      sudo dnf install -y gum
    else
      echo "   ⚠️  Unknown Linux distro. Install manually: https://github.com/charmbracelet/gum#installation"
    fi
  fi
  echo ""
fi

WORKSPACE_ROOT="$(pwd)"

# =============================================================================
# CREATE DIRECTORIES
# =============================================================================

echo "📁 Creating directories..."
mkdir -p .cursor/ralph-scripts
mkdir -p .ralph

# =============================================================================
# DOWNLOAD SCRIPTS
# =============================================================================

echo "📥 Downloading Ralph scripts..."

SCRIPTS=(
  "ralph-common.sh"
  "ralph-setup.sh"
  "ralph-loop.sh"
  "ralph-once.sh"
  "stream-parser.sh"
  "init-ralph.sh"
)

for script in "${SCRIPTS[@]}"; do
  if curl -fsSL "$REPO_RAW/scripts/$script" -o ".cursor/ralph-scripts/$script" 2>/dev/null; then
    chmod +x ".cursor/ralph-scripts/$script"
  else
    echo "   ⚠️  Could not download $script (may not exist yet)"
  fi
done

echo "✓ Scripts installed to .cursor/ralph-scripts/"


# =============================================================================
# INITIALIZE .ralph/ STATE (shared guardrails only)
# =============================================================================

echo "📁 Initializing .ralph/ state directory..."

# Only create guardrails.md at the top level (shared across runs)
# Per-run state (activity.log, errors.log, progress.md) is created in .ralph/runs/<runId>/
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
# CREATE RALPH_TASK.md TEMPLATE
# =============================================================================

if [[ ! -f "RALPH_TASK.md" ]]; then
  echo "📝 Creating RALPH_TASK.md template..."
  cat > RALPH_TASK.md <<'TASKEOF'
---
task: Build a CLI todo app in TypeScript
test_command: "npx ts-node todo.ts list"
---

# Task: CLI Todo App (TypeScript)

Build a simple command-line todo application in TypeScript.

## Requirements

1. Single file: `todo.ts`
2. Uses `todos.json` for persistence
3. Three commands: add, list, done
4. TypeScript with proper types

## Success Criteria

The following will be converted to Beads tasks when you first run Ralph:

1. `npx ts-node todo.ts add "Buy milk"` adds a todo and confirms
2. `npx ts-node todo.ts list` shows all todos with IDs and status
3. `npx ts-node todo.ts done 1` marks todo 1 as complete
4. Todos survive script restart (JSON persistence)
5. Invalid commands show helpful usage message
6. Code has proper TypeScript types (no `any`)

## Example Output

```
$ npx ts-node todo.ts add "Buy milk"
✓ Added: "Buy milk" (id: 1)

$ npx ts-node todo.ts list
1. [ ] Buy milk

$ npx ts-node todo.ts done 1
✓ Completed: "Buy milk"
```

## Notes

- This task file defines the work to be done
- When Ralph runs, it creates Beads issues from Success Criteria
- Progress is tracked via Beads (`bd list`, `bd ready`, etc.)
- Each run gets isolated state in `.ralph/runs/<runId>/`
TASKEOF
  echo "✓ Created RALPH_TASK.md with example task"
else
  echo "✓ RALPH_TASK.md already exists (not overwritten)"
fi

# =============================================================================
# UPDATE .gitignore
# =============================================================================

if [[ -f ".gitignore" ]]; then
  if ! grep -q "ralph-config.json" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Ralph config (may contain API key)" >> .gitignore
    echo ".cursor/ralph-config.json" >> .gitignore
  fi
else
  cat > .gitignore <<'EOF'
# Ralph config (may contain API key)
.cursor/ralph-config.json
EOF
fi
echo "✓ Updated .gitignore"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if [[ "$BEADS_MISSING" == "true" ]]; then
  echo "⚠️  Ralph installed (with warnings)"
else
  echo "✅ Ralph installed!"
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
echo ""
echo "  📁 .cursor/ralph-scripts/"
echo "     ├── ralph-setup.sh          - Main entry (interactive)"
echo "     ├── ralph-loop.sh           - CLI mode (for scripting)"
echo "     ├── ralph-once.sh           - Single iteration (testing)"
echo "     └── ...                     - Other utilities"
echo ""
echo "  📁 .ralph/"
echo "     └── guardrails.md           - Lessons learned (shared)"
echo ""
echo "  📁 .ralph/runs/<runId>/        - Per-run state (created on first run)"
echo "     ├── progress.md             - Progress log"
echo "     ├── activity.log            - Tool call log"
echo "     ├── errors.log              - Failure log"
echo "     ├── beads.label             - Beads label for this run"
echo "     └── beads.root_id           - Root epic ID"
echo ""
echo "  📄 RALPH_TASK.md               - Your task definition (edit this!)"
echo ""
echo "Next steps:"
if [[ "$BEADS_MISSING" == "true" ]]; then
  echo "  1. Install Beads (see above)"
  echo "  2. Edit RALPH_TASK.md to define your actual task"
  echo "  3. Run: ./.cursor/ralph-scripts/ralph-setup.sh"
else
  echo "  1. Edit RALPH_TASK.md to define your actual task"
  echo "  2. Run: ./.cursor/ralph-scripts/ralph-setup.sh"
fi
echo ""
echo "Parallel runs (different task files):"
echo "  ./.cursor/ralph-scripts/ralph-loop.sh --task-file TASK_A.md --run-id a"
echo "  ./.cursor/ralph-scripts/ralph-loop.sh --task-file TASK_B.md --run-id b"
echo ""
echo "Monitor progress:"
echo "  bd list --json                 # See all Beads tasks"
echo "  tail -f .ralph/runs/<runId>/activity.log"
echo ""
echo "Learn more:"
echo "  Ralph: https://ghuntley.com/ralph/"
echo "  Beads: https://github.com/steveyegge/beads"
echo "═══════════════════════════════════════════════════════════════════"
