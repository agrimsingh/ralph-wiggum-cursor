#!/bin/bash
# Ralph Wiggum: Interactive Setup & Loop
#
# THE main entry point for Ralph. Uses gum for a beautiful CLI experience,
# falls back to simple prompts if gum is not installed.
#
# Usage:
#   ./ralph-setup.sh                    # Interactive setup + run loop
#   ./ralph-setup.sh /path/to/project   # Run in specific project
#
# Requirements:
#   - RALPH_TASK.md in the project root
#   - Git repository
#   - cursor-agent CLI installed
#   - gum (optional, for enhanced UI): brew install gum

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/ralph-common.sh"
source "$SCRIPT_DIR/task-parser.sh"

# Source parallel execution (if available)
if [[ -f "$SCRIPT_DIR/ralph-parallel.sh" ]]; then
  source "$SCRIPT_DIR/ralph-parallel.sh"
fi

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
  local current_model="$1"
  local keep_current_label="Keep current (${current_model})"
  local model_options=("$keep_current_label" "${MODELS[@]}")
  local selected=""

  if [[ "$HAS_GUM" == "true" ]]; then
    # Keep all interactive UI in stderr; only emit the final model on stdout.
    selected="$(gum choose --header "Select model:" "${model_options[@]}" || true)"

    if [[ "$selected" == "$keep_current_label" ]]; then
      selected="$current_model"
    elif [[ "$selected" == "Custom..." ]]; then
      selected="$(gum input --placeholder "Enter model name" --value "$current_model" || true)"
    fi
  else
    echo "" >&2
    echo "Select model:" >&2
    local i=0
    for m in "${model_options[@]}"; do
      if [[ "$m" == "Custom..." ]]; then
        echo "  $i) Custom (enter manually)" >&2
      else
        echo "  $i) $m" >&2
      fi
      ((i++))
    done
    echo "" >&2
    read -p "Choice [0]: " choice
    choice="${choice:-0}"
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 0 ]] && [[ "$choice" -lt ${#model_options[@]} ]]; then
      local selected="${model_options[$choice]}"
      if [[ "$selected" == "$keep_current_label" ]]; then
        selected="$current_model"
      elif [[ "$selected" == "Custom..." ]]; then
        read -p "Enter model name [$current_model]: " selected
        selected="${selected:-$current_model}"
      fi
    else
      echo "Invalid choice. Keeping current model." >&2
      selected="$current_model"
    fi
  fi

  selected="${selected:-$current_model}"

  # Defensive guard: keep current model if selection is malformed.
  local invalid_reason=""
  if invalid_reason="$(model_value_invalid_reason "$selected")"; then
    echo "Invalid model selection ($invalid_reason). Keeping current model." >&2
    selected="$current_model"
  fi

  printf '%s\n' "$selected"
}

# Get max iterations using gum or fallback
get_max_iterations() {
  local current_iterations="$1"

  if [[ "$HAS_GUM" == "true" ]]; then
    local value
    value=$(gum input --header "Max iterations:" --placeholder "$current_iterations" --value "$current_iterations")
    echo "${value:-$current_iterations}"
  else
    read -p "Max iterations [$current_iterations]: " value
    echo "${value:-$current_iterations}"
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
    "Run in parallel mode"
  )
  
  if [[ "$HAS_GUM" == "true" ]]; then
    # gum choose --no-limit returns newline-separated selections
    local selected
    selected=$(gum choose --no-limit --header "Options (space to select, enter to confirm):" "${options[@]}") || true
    echo "$selected"
  else
    echo "" >&2
    echo "Options (enter numbers separated by spaces, or press Enter to skip):" >&2
    local i=1
    for opt in "${options[@]}"; do
      echo "  $i) $opt" >&2
      ((i++))
    done
    echo "" >&2
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

# Get max parallel agents using gum or fallback
get_max_parallel() {
  if [[ "$HAS_GUM" == "true" ]]; then
    local value
    value=$(gum input --header "Max parallel agents:" --placeholder "3" --value "3")
    echo "${value:-3}"
  else
    read -p "Max parallel agents [3]: " value
    echo "${value:-3}"
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
  local workspace="${1:-.}"
  if [[ "$workspace" == "." ]]; then
    workspace="$(pwd)"
  fi
  workspace="$(cd "$workspace" && pwd)"
  
  local task_file="$workspace/RALPH_TASK.md"
  
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
  if ! check_prerequisites "$workspace"; then
    exit 1
  fi
  
  # Initialize .ralph directory
  init_ralph_dir "$workspace"
  
  echo "Workspace: $workspace"
  echo ""
  
  # Show task summary
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  
  # Count criteria
  local total_criteria done_criteria remaining
  # Only count actual checkbox list items (- [ ], * [x], 1. [ ], etc.)
  total_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total_criteria=0
  done_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_criteria=0
  remaining=$((total_criteria - done_criteria))
  
  echo "Progress: $done_criteria / $total_criteria criteria complete ($remaining remaining)"
  echo ""
  
  if [[ "$remaining" -eq 0 ]] && [[ "$total_criteria" -gt 0 ]]; then
    echo "🎉 Task already complete! All criteria are checked."
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
  
  # Resolve runtime configuration once for setup defaults.
  resolve_ralph_runtime_config

  # 1. Select model (defaults to resolved runtime model)
  MODEL=$(select_model "$MODEL")
  RALPH_MODEL="$MODEL"
  echo "✓ Model: $MODEL"
  
  # 2. Max iterations (defaults to resolved runtime value)
  MAX_ITERATIONS=$(get_max_iterations "$MAX_ITERATIONS")
  echo "✓ Max iterations: $MAX_ITERATIONS"
  
  # 3. Options
  local selected_options
  selected_options=$(select_options)
  
  # Parse selected options
  local run_single_first=false
  local parallel_mode=false
  local max_parallel=3
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
      "Run in parallel mode")
        parallel_mode=true
        max_parallel=$(get_max_parallel)
        echo "✓ Parallel mode: $max_parallel agents"
        ;;
    esac
  done <<< "$selected_options"
  
  # Validate: PR requires branch
  # (Sequential mode only) In parallel mode, integration branch is optional.
  if [[ "$OPEN_PR" == "true" ]] && [[ "$parallel_mode" != "true" ]] && [[ -z "$USE_BRANCH" ]]; then
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
  [[ -n "$USE_BRANCH" ]] && echo "  • Branch:     $USE_BRANCH"
  [[ "$OPEN_PR" == "true" ]] && echo "  • Open PR:    Yes"
  [[ "$run_single_first" == "true" ]] && echo "  • Test first: Yes (single iteration)"
  [[ "$parallel_mode" == "true" ]] && echo "  • Parallel:   $max_parallel agents"
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
  export RALPH_MODEL
  export MAX_ITERATIONS
  export WARN_THRESHOLD
  export ROTATE_THRESHOLD
  export USE_BRANCH
  export OPEN_PR
  
  # Handle single iteration first
  if [[ "$run_single_first" == "true" ]]; then
    echo ""
    echo "🧪 Running single iteration first..."
    echo ""
    
    # Run just one iteration
    local signal
    signal=$(run_iteration "$workspace" "1" "" "$SCRIPT_DIR")

    if [[ "$signal" == "CONFIG_ERROR" ]]; then
      echo ""
      echo "❌ Invalid runtime configuration. See .ralph/errors.log for details."
      exit 1
    fi
    
    # Check result
    local task_status
    task_status=$(check_task_complete "$workspace")
    
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
      signal=$(run_iteration "$workspace" "$iteration" "$session_id" "$SCRIPT_DIR")
      task_status=$(check_task_complete "$workspace")
      
      if [[ "$task_status" == "COMPLETE" ]]; then
        log_progress "$workspace" "**Session $iteration ended** - ✅ TASK COMPLETE"
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo "🎉 RALPH COMPLETE! All criteria satisfied."
        echo "═══════════════════════════════════════════════════════════════════"
        echo ""
        echo "Completed in $iteration iteration(s)."
        
        # Open PR if requested
        if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
          echo ""
          echo "📝 Opening pull request..."
          cd "$workspace"
          git push -u origin "$USE_BRANCH" 2>/dev/null || git push
          if command -v gh &> /dev/null; then
            gh pr create --fill || echo "⚠️  Could not create PR automatically."
          fi
        fi
        
        exit 0
      fi
      
      case "$signal" in
        "ROTATE")
          log_progress "$workspace" "**Session $iteration ended** - 🔄 Context rotation"
          echo "🔄 Rotating to fresh context..."
          iteration=$((iteration + 1))
          session_id=""
          ;;
        "GUTTER")
          log_progress "$workspace" "**Session $iteration ended** - 🚨 GUTTER"
          echo "🚨 Gutter detected. Check .ralph/errors.log"
          exit 1
          ;;
        "CONFIG_ERROR")
          log_progress "$workspace" "**Session $iteration ended** - ❌ CONFIG_ERROR (invalid runtime configuration)"
          echo "❌ Invalid runtime configuration. Check .ralph/errors.log"
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
  
  # Run parallel or sequential mode
  if [[ "$parallel_mode" == "true" ]]; then
    # Check if parallel functions are available
    if ! type run_parallel_tasks &>/dev/null; then
      echo "❌ Parallel execution not available (ralph-parallel.sh not found)"
      exit 1
    fi
    
    # Export settings for parallel execution
    export MODEL
    export SKIP_MERGE=false
    export CREATE_PR="$OPEN_PR"

    local base_branch
    base_branch="$(git -C "$workspace" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

    # Args: workspace, max_parallel, base_branch, integration_branch(optional)
    run_parallel_tasks "$workspace" "$max_parallel" "$base_branch" "$USE_BRANCH"
    exit $?
  else
    # Run full sequential loop
    run_ralph_loop "$workspace" "$SCRIPT_DIR"
    exit $?
  fi
}

main "$@"
