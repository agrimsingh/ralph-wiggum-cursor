#!/bin/bash
# Ralph Wiggum: Single Iteration (Human-in-the-Loop)
#
# Runs exactly ONE iteration of the Ralph loop, then stops.
# Useful for testing your task definition before going AFK.
#
# Usage:
#   ./ralph-once.sh                    # Run single iteration
#   ./ralph-once.sh /path/to/project   # Run in specific project
#   ./ralph-once.sh -m gpt-5.2-high    # Use specific model
#   ./ralph-once.sh --task-file TASK_A.md  # Use different task file
#   ./ralph-once.sh --run-id myrun     # Use specific run ID
#
# After running:
#   - Review the changes made
#   - Check git log for commits
#   - If satisfied, run ralph-setup.sh or ralph-loop.sh for full loop
#
# Requirements:
#   - Task file (default: RALPH_TASK.md) in the project root
#   - Git repository
#   - cursor-agent CLI installed
#   - bd (Beads) CLI installed and initialized

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# FLAG PARSING
# =============================================================================

show_help() {
  cat << 'EOF'
Ralph Wiggum: Single Iteration (Human-in-the-Loop)

Runs exactly ONE iteration, then stops for review.
This is the recommended way to test your task definition.

Usage:
  ./ralph-once.sh [options] [workspace]

Options:
  -m, --model MODEL      Model to use (default: opus-4.5-thinking)
  -f, --task-file FILE   Task file to use (default: RALPH_TASK.md)
  -r, --run-id ID        Run ID for state isolation (default: derived from task file)
  -h, --help             Show this help

Examples:
  ./ralph-once.sh                                    # Run one iteration
  ./ralph-once.sh -m sonnet-4.5-thinking             # Use Sonnet model
  ./ralph-once.sh --task-file TASK_A.md --run-id a  # Test parallel run A

Environment:
  RALPH_MODEL            Override default model (same as -m flag)
  RALPH_TASK_FILE        Override default task file (same as -f flag)
  RALPH_RUN_ID           Override run ID (same as -r flag)

After reviewing the results:
  - If satisfied: run ./ralph-setup.sh for full loop
  - If issues: fix them, update task file or guardrails, run again
EOF
}

# Parse command line arguments
WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)
      MODEL="$2"
      shift 2
      ;;
    -f|--task-file)
      TASK_FILE="$2"
      shift 2
      ;;
    -r|--run-id)
      RUN_ID="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      echo "Use -h for help."
      exit 1
      ;;
    *)
      # Positional argument = workspace
      WORKSPACE="$1"
      shift
      ;;
  esac
done

# =============================================================================
# MAIN
# =============================================================================

main() {
  # Resolve workspace
  if [[ -z "$WORKSPACE" ]]; then
    WORKSPACE="$(pwd)"
  elif [[ "$WORKSPACE" == "." ]]; then
    WORKSPACE="$(pwd)"
  else
    WORKSPACE="$(cd "$WORKSPACE" && pwd)"
  fi
  
  # Resolve task file
  local task_file
  task_file=$(resolve_task_file "$WORKSPACE" "$TASK_FILE")
  
  # Derive or use provided run ID
  local run_id="${RUN_ID:-}"
  if [[ -z "$run_id" ]]; then
    run_id=$(derive_run_id "$task_file" "$WORKSPACE")
  fi
  
  # Get run directory
  local run_dir
  run_dir=$(get_run_dir "$WORKSPACE" "$run_id")
  
  # Show banner
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: Single Iteration (Human-in-the-Loop)"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  This runs ONE iteration, then stops for your review."
  echo "  Use this to test your task before going AFK."
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  
  # Check prerequisites
  if ! check_prerequisites "$WORKSPACE" "$task_file"; then
    exit 1
  fi
  
  # Initialize run directory
  init_run_dir "$run_dir"
  
  # Initialize shared guardrails
  init_guardrails "$WORKSPACE"
  
  # Bootstrap Beads issues if not already done
  if ! is_beads_initialized "$run_dir"; then
    bootstrap_beads_from_task_md "$WORKSPACE" "$task_file" "$run_dir" "$run_id"
  fi
  
  echo "Workspace:  $WORKSPACE"
  echo "Task file:  $task_file"
  echo "Run ID:     $run_id"
  echo "Model:      $MODEL"
  echo ""
  
  # Show task summary
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  
  # Count criteria via Beads
  local counts
  counts=$(count_criteria "$run_dir")
  local done_criteria="${counts%%:*}"
  local total_criteria="${counts##*:}"
  local remaining=$((total_criteria - done_criteria))
  
  echo "Progress: $done_criteria / $total_criteria tasks complete ($remaining remaining)"
  echo ""
  
  if [[ "$remaining" -eq 0 ]] && [[ "$total_criteria" -gt 0 ]]; then
    echo "🎉 Task already complete! All Beads tasks are closed."
    exit 0
  fi
  
  # Confirm
  read -p "Run single iteration? [Y/n] " -n 1 -r
  echo ""
  
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  
  # Commit any uncommitted work first
  cd "$WORKSPACE"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: checkpoint before single iteration" || true
  fi
  
  echo ""
  echo "🚀 Running single iteration..."
  echo ""
  
  # Run exactly one iteration
  local signal
  signal=$(run_iteration "$WORKSPACE" "1" "" "$SCRIPT_DIR" "$task_file" "$run_dir")
  
  # Check result
  local task_status
  task_status=$(check_task_complete "$run_dir")
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "📋 Single Iteration Complete"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  
  case "$signal" in
    "COMPLETE")
      if [[ "$task_status" == "COMPLETE" ]]; then
        echo "🎉 Task completed in single iteration!"
        echo ""
        echo "All Beads tasks are closed. You're done!"
      else
        echo "⚠️  Agent signaled complete but some tasks remain open."
        echo "   Review the results and run again if needed."
      fi
      ;;
    "GUTTER")
      echo "🚨 Gutter detected - agent got stuck."
      echo ""
      echo "Review $run_dir/errors.log and consider:"
      echo "  1. Adding a guardrail to .ralph/guardrails.md"
      echo "  2. Simplifying the task"
      echo "  3. Fixing the blocking issue manually"
      ;;
    "ROTATE")
      echo "🔄 Context rotation was triggered."
      echo ""
      echo "The agent used a lot of context. This is normal for complex tasks."
      echo "Review the progress and run again or proceed to full loop."
      ;;
    *)
      if [[ "$task_status" == "COMPLETE" ]]; then
        echo "🎉 Task completed in single iteration!"
      else
        local remaining_count=${task_status#INCOMPLETE:}
        echo "Agent finished with $remaining_count tasks remaining."
      fi
      ;;
  esac
  
  echo ""
  echo "Review the changes:"
  echo "  • git log --oneline -5     # See recent commits"
  echo "  • git diff HEAD~1          # See changes"
  echo "  • cat $run_dir/progress.md   # See progress log"
  echo "  • bd list --label ralph:$run_id --json  # See Beads tasks"
  echo ""
  echo "Next steps:"
  echo "  • If satisfied: ./ralph-setup.sh --task-file $task_file --run-id $run_id  # Run full loop"
  echo "  • If issues: fix, update task/guardrails, ./ralph-once.sh again"
  echo ""
}

main
