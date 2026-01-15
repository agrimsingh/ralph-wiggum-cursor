#!/bin/bash
# Ralph Wiggum: The Loop (DEPRECATED)
#
# This script is deprecated. Use 'ralph' instead.
#
# Migration:
#   ./ralph-loop.sh --task-file plans/api.md
#   → ralph --task-file plans/api.md
#
# This wrapper delegates to 'ralph' and will be removed in a future version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print deprecation warning to stderr
echo "⚠️  WARNING: ralph-loop.sh is deprecated. Use 'ralph' instead." >&2
echo "   Migration: ./ralph-loop.sh [args] → ralph [args]" >&2
echo "" >&2

# Delegate to ralph
exec "$SCRIPT_DIR/ralph" "$@"

# =============================================================================
# FLAG PARSING
# =============================================================================

show_help() {
  cat << 'EOF'
Ralph Wiggum: The Loop (CLI Mode)

Usage:
  ./ralph-loop.sh [options] [workspace]

Options:
  -n, --iterations N     Max iterations (default: 20)
  -m, --model MODEL      Model to use (default: opus-4.5-thinking)
  -f, --task-file FILE   Task/plan file path (bring your own plan doc)
                         Falls back to RALPH_TASK.md if present
  -r, --run-id ID        Run ID for state isolation (default: derived from task file)
  --branch NAME          Create and work on a new branch
  --pr                   Open PR when complete (requires --branch)
  -y, --yes              Skip confirmation prompt
  -h, --help             Show this help

Examples:
  # Run with your own plan file (recommended)
  ./ralph-loop.sh --task-file plans/api.md

  # Multiple parallel runs
  ./ralph-loop.sh --task-file plans/api.md --run-id api -y &
  ./ralph-loop.sh --task-file plans/ui.md --run-id ui -y &

  # Scripted PR workflow
  ./ralph-loop.sh --task-file plans/api.md --branch feature/api --pr -y

  # Custom model and iterations
  ./ralph-loop.sh --task-file plans/api.md -n 50 -m gpt-5.2-high

  # Get the task template
  ../init-ralph.sh --print-template > plans/my-task.md
  
Environment:
  RALPH_MODEL            Override default model (same as -m flag)
  RALPH_TASK_FILE        Override task file (same as -f flag)
  RALPH_RUN_ID           Override run ID (same as -r flag)

For interactive setup with a beautiful UI, use ralph-setup.sh instead.
EOF
}

# Parse command line arguments
WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
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
    --branch)
      USE_BRANCH="$2"
      shift 2
      ;;
    --pr)
      OPEN_PR=true
      shift
      ;;
    -y|--yes)
      SKIP_CONFIRM=true
      shift
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
  show_banner
  
  # Check prerequisites
  if ! check_prerequisites "$WORKSPACE" "$task_file"; then
    exit 1
  fi
  
  # Validate: PR requires branch
  if [[ "$OPEN_PR" == "true" ]] && [[ -z "$USE_BRANCH" ]]; then
    echo "❌ --pr requires --branch"
    echo "   Example: ./ralph-loop.sh --branch feature/foo --pr"
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
  echo "Run dir:    $run_dir"
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
  echo "Model:    $MODEL"
  echo "Max iter: $MAX_ITERATIONS"
  [[ -n "$USE_BRANCH" ]] && echo "Branch:   $USE_BRANCH"
  [[ "$OPEN_PR" == "true" ]] && echo "Open PR:  Yes"
  echo ""
  
  if [[ "$remaining" -eq 0 ]] && [[ "$total_criteria" -gt 0 ]]; then
    echo "🎉 Task already complete! All Beads tasks are closed."
    exit 0
  fi
  
  # Confirm before starting (unless -y flag)
  if [[ "$SKIP_CONFIRM" != "true" ]]; then
    echo "This will run cursor-agent locally to work on this task."
    echo "The agent will be rotated when context fills up (~80k tokens)."
    echo ""
    echo "Tip: Use ralph-setup.sh for interactive model/option selection."
    echo "     Use -y flag to skip this prompt."
    echo ""
    read -p "Start Ralph loop? [y/N] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi
  
  # Run the loop
  run_ralph_loop "$WORKSPACE" "$SCRIPT_DIR" "$task_file" "$run_dir"
  exit $?
}

main
