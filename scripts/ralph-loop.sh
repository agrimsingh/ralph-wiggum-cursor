#!/bin/bash
# Ralph Wiggum: The Loop
# 
# This is the TRUE Ralph - a loop that keeps spawning agents until the task is done.
#
# Usage:
#   ./ralph-loop.sh                    # Start from current directory
#   ./ralph-loop.sh /path/to/project   # Start from specific project
#
# Requirements:
#   - RALPH_TASK.md in the project root
#   - Git repository with GitHub remote
#   - CURSOR_API_KEY or ~/.cursor/ralph-config.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# CONFIGURATION  
# =============================================================================

CONFIG_FILE="${1:-.}/.cursor/ralph-config.json"
GLOBAL_CONFIG="$HOME/.cursor/ralph-config.json"

# =============================================================================
# HELPERS
# =============================================================================

get_api_key() {
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then echo "$CURSOR_API_KEY" && return 0; fi
  if [[ -f "$CONFIG_FILE" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$KEY" ]]; then echo "$KEY" && return 0; fi
  fi
  if [[ -f "$GLOBAL_CONFIG" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$GLOBAL_CONFIG" 2>/dev/null || echo "")
    if [[ -n "$KEY" ]]; then echo "$KEY" && return 0; fi
  fi
  return 1
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  WORKSPACE="${1:-.}"
  if [[ "$WORKSPACE" == "." ]]; then
    WORKSPACE="$(pwd)"
  fi
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"
  
  TASK_FILE="$WORKSPACE/RALPH_TASK.md"
  
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: The Loop"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  \"That's the beauty of Ralph - the technique is deterministically"
  echo "   bad in an undeterministic world.\""
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  
  # Check prerequisites
  if [[ ! -f "$TASK_FILE" ]]; then
    echo "❌ No RALPH_TASK.md found in $WORKSPACE"
    echo ""
    echo "Create a task file first:"
    echo "  cat > RALPH_TASK.md << 'EOF'"
    echo "  ---"
    echo "  task: Your task description"
    echo "  test_command: \"npm test\""
    echo "  ---"
    echo "  # Task"
    echo "  ## Success Criteria"
    echo "  1. [ ] First thing to do"
    echo "  2. [ ] Second thing to do"
    echo "  EOF"
    exit 1
  fi
  
  API_KEY=$(get_api_key) || {
    echo "❌ No Cursor API key configured"
    echo ""
    echo "Configure via:"
    echo "  export CURSOR_API_KEY='your-key'"
    echo "  # or"
    echo "  echo '{\"cursor_api_key\": \"key\"}' > ~/.cursor/ralph-config.json"
    echo ""
    echo "Get your key from: https://cursor.com/dashboard?tab=integrations"
    exit 1
  }
  
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not a git repository"
    echo "   Ralph Cloud requires a GitHub repository."
    exit 1
  fi
  
  REPO_URL=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ -z "$REPO_URL" ]]; then
    echo "❌ No git remote 'origin' configured"
    echo "   Run: git remote add origin https://github.com/you/repo"
    exit 1
  fi
  
  echo "Workspace: $WORKSPACE"
  echo "Task:      $TASK_FILE"
  echo "Repo:      $REPO_URL"
  echo ""
  
  # Show task summary
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$TASK_FILE"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  
  # Count criteria (supports both "- [ ]" and "1. [ ]" formats)
  TOTAL_CRITERIA=$(grep -cE '\[ \]|\[x\]' "$TASK_FILE" 2>/dev/null || echo "0")
  DONE_CRITERIA=$(grep -c '\[x\]' "$TASK_FILE" 2>/dev/null || echo "0")
  # Ensure we have valid integers (strip whitespace, default to 0)
  TOTAL_CRITERIA=$(echo "$TOTAL_CRITERIA" | tr -cd '0-9')
  DONE_CRITERIA=$(echo "$DONE_CRITERIA" | tr -cd '0-9')
  [[ -z "$TOTAL_CRITERIA" ]] && TOTAL_CRITERIA=0
  [[ -z "$DONE_CRITERIA" ]] && DONE_CRITERIA=0
  REMAINING=$((TOTAL_CRITERIA - DONE_CRITERIA))
  
  echo "Progress: $DONE_CRITERIA / $TOTAL_CRITERIA criteria complete ($REMAINING remaining)"
  echo ""
  
  if [[ "$REMAINING" -eq 0 ]] && [[ "$TOTAL_CRITERIA" -gt 0 ]]; then
    echo "🎉 Task already complete! All criteria are checked."
    exit 0
  fi
  
  # Confirm before starting
  echo "This will spawn Cloud Agents to work on this task autonomously."
  echo "Agents will be chained until the task is complete (or max depth reached)."
  echo ""
  read -p "Start Ralph loop? [y/N] " -n 1 -r
  echo ""
  
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  
  echo ""
  echo "🚀 Starting Ralph loop..."
  echo ""
  
  # Commit any uncommitted work first
  cd "$WORKSPACE"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: initial commit before loop" || true
    git push origin HEAD 2>/dev/null || true
  fi
  
  # Spawn first agent
  echo ""
  SPAWN_OUTPUT=$("$SCRIPT_DIR/spawn-cloud-agent.sh" "$WORKSPACE" 2>&1)
  echo "$SPAWN_OUTPUT"
  
  AGENT_ID=$(echo "$SPAWN_OUTPUT" | grep "Agent ID:" | awk '{print $NF}')
  
  if [[ -z "$AGENT_ID" ]]; then
    echo ""
    echo "❌ Failed to spawn initial agent"
    exit 1
  fi
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🔁 Entering watch loop..."
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  
  # Start the watcher
  "$SCRIPT_DIR/watch-cloud-agent.sh" "$AGENT_ID" "$WORKSPACE"
}

main "$@"
