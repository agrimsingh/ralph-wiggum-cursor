#!/bin/bash
# Ralph Wiggum: Interactive Setup & Loop
#
# THE main entry point for Ralph. Uses gum for a beautiful CLI experience,
# falls back to simple prompts if gum is not installed.
#
# Usage:
#   ./ralph-setup.sh                    # Interactive setup + run loop
#   ./ralph-setup.sh /path/to/project   # Run in specific project
#   ./ralph-setup.sh --task-file TASK_A.md  # Use different task file
#   ./ralph-setup.sh --run-id myrun     # Use specific run ID
#
# Requirements:
#   - Task file (default: RALPH_TASK.md) in the project root
#   - Git repository
#   - cursor-agent CLI installed
#   - bd (Beads) CLI installed and initialized
#   - gum (optional, for enhanced UI): brew install gum

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# FLAG PARSING
# =============================================================================

show_help() {
  cat << 'EOF'
Ralph Wiggum: Interactive Setup & Loop

Usage:
  ./ralph-setup.sh [options] [workspace]

Options:
  -f, --task-file FILE   Task file to use (default: RALPH_TASK.md)
  -r, --run-id ID        Run ID for state isolation (default: derived from task file)
  -h, --help             Show this help

Examples:
  ./ralph-setup.sh                                    # Interactive mode
  ./ralph-setup.sh /path/to/project                   # Specific project
  ./ralph-setup.sh --task-file TASK_A.md --run-id a  # Parallel run

Environment:
  RALPH_TASK_FILE        Override default task file (same as -f flag)
  RALPH_RUN_ID           Override run ID (same as -r flag)

For CLI mode with flags, use ralph-loop.sh instead.
EOF
}

# Parse command line arguments
WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
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
# GUM DETECTION
# =============================================================================

HAS_GUM=false
if command -v gum &> /dev/null; then
  HAS_GUM=true
fi

# =============================================================================
# GUM UI HELPERS
# =============================================================================

# Model options
MODELS=(
  "opus-4.5-thinking"
  "sonnet-4.5-thinking"
  "gpt-5.2-high"
  "composer-1"
  "Custom..."
)

# Select model using gum or fallback
select_model() {
  if [[ "$HAS_GUM" == "true" ]]; then
    local selected
    selected=$(gum choose --header "Select model:" "${MODELS[@]}")
    
    if [[ "$selected" == "Custom..." ]]; then
      selected=$(gum input --placeholder "Enter model name" --value "$DEFAULT_MODEL")
    fi
    echo "$selected"
  else
    echo ""
    echo "Select model:"
    local i=1
    for m in "${MODELS[@]}"; do
      if [[ "$m" == "Custom..." ]]; then
        echo "  $i) Custom (enter manually)"
      else
        echo "  $i) $m"
      fi
      ((i++))
    done
    echo ""
    read -p "Choice [1]: " choice
    choice="${choice:-1}"
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#MODELS[@]} ]]; then
      local selected="${MODELS[$((choice-1))]}"
      if [[ "$selected" == "Custom..." ]]; then
        read -p "Enter model name: " selected
      fi
      echo "$selected"
    else
      echo "${MODELS[0]}"
    fi
  fi
}

# Get max iterations using gum or fallback
get_max_iterations() {
  if [[ "$HAS_GUM" == "true" ]]; then
    local value
    value=$(gum input --header "Max iterations:" --placeholder "20" --value "20")
    echo "${value:-20}"
  else
    read -p "Max iterations [20]: " value
    echo "${value:-20}"
  fi
}

# Multi-select options using gum or fallback
# Returns space-separated list of selected options
select_options() {
  local options=(
    "Commit to current branch"
    "Run single iteration first"
    "Work on new branch"
    "Open PR when complete"
  )
  
  if [[ "$HAS_GUM" == "true" ]]; then
    # gum choose --no-limit returns newline-separated selections
    local selected
    selected=$(gum choose --no-limit --header "Options (space to select, enter to confirm):" "${options[@]}") || true
    echo "$selected"
  else
    echo ""
    echo "Options (enter numbers separated by spaces, or press Enter to skip):"
    local i=1
    for opt in "${options[@]}"; do
      echo "  $i) $opt"
      ((i++))
    done
    echo ""
    read -p "Select options [none]: " choices
    
    local selected=""
    for choice in $choices; do
      if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#options[@]} ]]; then
        if [[ -n "$selected" ]]; then
          selected="$selected"$'\n'"${options[$((choice-1))]}"
        else
          selected="${options[$((choice-1))]}"
        fi
      fi
    done
    echo "$selected"
  fi
}

# Get branch name using gum or fallback
get_branch_name() {
  if [[ "$HAS_GUM" == "true" ]]; then
    gum input --header "Branch name:" --placeholder "feature/my-feature"
  else
    read -p "Branch name: " branch
    echo "$branch"
  fi
}

# Confirm action using gum or fallback
confirm_action() {
  local message="$1"
  
  if [[ "$HAS_GUM" == "true" ]]; then
    gum confirm "$message"
  else
    read -p "$message [y/N] " -n 1 -r
    echo ""
    [[ $REPLY =~ ^[Yy]$ ]]
  fi
}

# Show styled header
show_header() {
  local text="$1"
  if [[ "$HAS_GUM" == "true" ]]; then
    gum style --border double --padding "0 2" --border-foreground 212 "$text"
  else
    echo "═══════════════════════════════════════════════════════════════════"
    echo "$text"
    echo "═══════════════════════════════════════════════════════════════════"
  fi
}

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
  echo ""
  show_header "🐛 Ralph Wiggum: Autonomous Development Loop"
  echo ""
  
  if [[ "$HAS_GUM" == "true" ]]; then
    echo "  Using gum for enhanced UI ✨"
  else
    echo "  💡 Install gum for a better experience: https://github.com/charmbracelet/gum#installation"
  fi
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
  
  # ==========================================================================
  # INTERACTIVE SETUP
  # ==========================================================================
  
  echo ""
  if [[ "$HAS_GUM" == "true" ]]; then
    gum style --foreground 212 "Configure your Ralph session:"
  else
    echo "Configure your Ralph session:"
  fi
  echo ""
  
  # 1. Select model
  MODEL=$(select_model)
  echo "✓ Model: $MODEL"
  
  # 2. Max iterations
  MAX_ITERATIONS=$(get_max_iterations)
  echo "✓ Max iterations: $MAX_ITERATIONS"
  
  # 3. Options
  local selected_options
  selected_options=$(select_options)
  
  # Parse selected options
  local run_single_first=false
  USE_BRANCH=""
  OPEN_PR=false
  
  while IFS= read -r opt; do
    case "$opt" in
      "Commit to current branch")
        echo "✓ Will commit to current branch"
        ;;
      "Run single iteration first")
        run_single_first=true
        echo "✓ Will run single iteration first"
        ;;
      "Work on new branch")
        USE_BRANCH=$(get_branch_name)
        echo "✓ Branch: $USE_BRANCH"
        ;;
      "Open PR when complete")
        OPEN_PR=true
        echo "✓ Will open PR when complete"
        ;;
    esac
  done <<< "$selected_options"
  
  # Validate: PR requires branch
  if [[ "$OPEN_PR" == "true" ]] && [[ -z "$USE_BRANCH" ]]; then
    echo ""
    echo "⚠️  Opening PR requires a branch. Please specify a branch name:"
    USE_BRANCH=$(get_branch_name)
    echo "✓ Branch: $USE_BRANCH"
  fi
  
  echo ""
  
  # ==========================================================================
  # CONFIRMATION
  # ==========================================================================
  
  echo "─────────────────────────────────────────────────────────────────"
  echo "Summary:"
  echo "  • Model:      $MODEL"
  echo "  • Iterations: $MAX_ITERATIONS max"
  echo "  • Task file:  $task_file"
  echo "  • Run ID:     $run_id"
  [[ -n "$USE_BRANCH" ]] && echo "  • Branch:     $USE_BRANCH"
  [[ "$OPEN_PR" == "true" ]] && echo "  • Open PR:    Yes"
  [[ "$run_single_first" == "true" ]] && echo "  • Test first: Yes (single iteration)"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  
  if ! confirm_action "Start Ralph loop?"; then
    echo "Aborted."
    exit 0
  fi
  
  # ==========================================================================
  # RUN LOOP
  # ==========================================================================
  
  # Export settings for the loop
  export MODEL
  export MAX_ITERATIONS
  export USE_BRANCH
  export OPEN_PR
  
  # Handle single iteration first
  if [[ "$run_single_first" == "true" ]]; then
    echo ""
    echo "🧪 Running single iteration first..."
    echo ""
    
    # Run just one iteration
    local signal
    signal=$(run_iteration "$WORKSPACE" "1" "" "$SCRIPT_DIR" "$task_file" "$run_dir")
    
    # Check result
    local task_status
    task_status=$(check_task_complete "$run_dir")
    
    if [[ "$task_status" == "COMPLETE" ]]; then
      echo ""
      echo "🎉 Task completed in single iteration!"
      exit 0
    fi
    
    echo ""
    echo "Single iteration complete. Review the changes."
    echo ""
    
    if ! confirm_action "Continue with full loop?"; then
      echo "Stopped after single iteration."
      exit 0
    fi
    
    # Continue with remaining iterations (start from 2)
    local iteration=2
    local session_id=""
    
    while [[ $iteration -le $MAX_ITERATIONS ]]; do
      signal=$(run_iteration "$WORKSPACE" "$iteration" "$session_id" "$SCRIPT_DIR" "$task_file" "$run_dir")
      task_status=$(check_task_complete "$run_dir")
      
      if [[ "$task_status" == "COMPLETE" ]]; then
        log_progress "$run_dir" "**Session $iteration ended** - ✅ TASK COMPLETE"
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo "🎉 RALPH COMPLETE! All Beads tasks satisfied."
        echo "═══════════════════════════════════════════════════════════════════"
        echo ""
        echo "Completed in $iteration iteration(s)."
        
        # Open PR if requested
        if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
          echo ""
          echo "📝 Opening pull request..."
          cd "$WORKSPACE"
          git push -u origin "$USE_BRANCH" 2>/dev/null || git push
          if command -v gh &> /dev/null; then
            gh pr create --fill || echo "⚠️  Could not create PR automatically."
          fi
        fi
        
        exit 0
      fi
      
      case "$signal" in
        "ROTATE")
          log_progress "$run_dir" "**Session $iteration ended** - 🔄 Context rotation"
          echo "🔄 Rotating to fresh context..."
          iteration=$((iteration + 1))
          session_id=""
          ;;
        "GUTTER")
          log_progress "$run_dir" "**Session $iteration ended** - 🚨 GUTTER"
          echo "🚨 Gutter detected. Check $run_dir/errors.log"
          exit 1
          ;;
        *)
          if [[ "$task_status" == INCOMPLETE:* ]]; then
            iteration=$((iteration + 1))
          fi
          ;;
      esac
      
      sleep 2
    done
    
    echo "⚠️  Max iterations reached."
    exit 1
  fi
  
  # Run full loop directly
  run_ralph_loop "$WORKSPACE" "$SCRIPT_DIR" "$task_file" "$run_dir"
  exit $?
}

main "$@"
