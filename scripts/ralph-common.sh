#!/bin/bash
# Ralph Wiggum: Common utilities and loop logic
#
# Shared functions for ralph-loop.sh and ralph-setup.sh
# All state lives in .ralph/ within the project.

# =============================================================================
# CONFIGURATION (can be overridden before sourcing)
# =============================================================================

# Token thresholds
WARN_THRESHOLD="${WARN_THRESHOLD:-70000}"
ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-80000}"

# Iteration limits
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"

# Model selection
DEFAULT_MODEL="opus-4.5-thinking"
MODEL="${RALPH_MODEL:-$DEFAULT_MODEL}"

# Feature flags (set by caller)
USE_BRANCH="${USE_BRANCH:-}"
OPEN_PR="${OPEN_PR:-false}"
SKIP_CONFIRM="${SKIP_CONFIRM:-false}"

# =============================================================================
# BASIC HELPERS
# =============================================================================

# Cross-platform sed -i
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Get the .ralph directory for a workspace
get_ralph_dir() {
  local workspace="${1:-.}"
  echo "$workspace/.ralph"
}

# Get current iteration from .ralph/.iteration
get_iteration() {
  local workspace="${1:-.}"
  local state_file="$workspace/.ralph/.iteration"
  
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo "0"
  fi
}

# Set iteration number
set_iteration() {
  local workspace="${1:-.}"
  local iteration="$2"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  echo "$iteration" > "$ralph_dir/.iteration"
}

# Increment iteration and return new value
increment_iteration() {
  local workspace="${1:-.}"
  local current=$(get_iteration "$workspace")
  local next=$((current + 1))
  set_iteration "$workspace" "$next"
  echo "$next"
}

# Get context health emoji based on token count
get_health_emoji() {
  local tokens="$1"
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  
  if [[ $pct -lt 60 ]]; then
    echo "🟢"
  elif [[ $pct -lt 80 ]]; then
    echo "🟡"
  else
    echo "🔴"
  fi
}

# Kill a process and all its descendants
kill_tree() {
  local pid="$1"
  local signal="${2:-TERM}"
  
  # First kill all children recursively
  local children
  children=$(pgrep -P "$pid" 2>/dev/null) || true
  for child in $children; do
    kill_tree "$child" "$signal"
  done
  
  # Then kill the process itself
  kill "-$signal" "$pid" 2>/dev/null || true
}

# Watchdog: monitors for blocking interactive processes (within the agent tree)
# Runs as background process and emits GUTTER if a blocking process is found.
# Args: agent_pid fifo workspace
run_watchdog() {
  local agent_pid="$1"
  local fifo="$2"
  local workspace="$3"
  local activity_log="$workspace/.ralph/activity.log"
  local errors_log="$workspace/.ralph/errors.log"

  list_descendants() {
    local root="$1"
    local kids
    kids=$(pgrep -P "$root" 2>/dev/null) || true
    for k in $kids; do
      echo "$k"
      list_descendants "$k"
    done
  }

  while kill -0 "$agent_pid" 2>/dev/null; do
    sleep 3

    local blocking=""
    local blocking_pid=""

    local pids=""
    pids="$(list_descendants "$agent_pid")"

    for pid in $pids; do
      local cmdline
      cmdline=$(ps -p "$pid" -o args= 2>/dev/null) || cmdline=""
      [[ -z "$cmdline" ]] && continue

      if [[ "$cmdline" =~ (^|[[:space:]])npm[[:space:]]+init($|[[:space:]]) ]] && [[ ! "$cmdline" =~ (-y|--yes) ]]; then
        blocking="npm init (use 'npm init -y' OR skip if package.json exists)"
        blocking_pid="$pid"
        break
      fi
      if [[ "$cmdline" =~ (^|[[:space:]])git[[:space:]]+commit($|[[:space:]]) ]] && [[ ! "$cmdline" =~ (-m|--message|-F|--file|--no-edit) ]]; then
        blocking="git commit (use 'git commit -m \"msg\"' or '--no-edit' for amend)"
        blocking_pid="$pid"
        break
      fi
      if [[ "$cmdline" =~ (^|[[:space:]])node($|[[:space:]]*$) ]]; then
        blocking="node REPL (use 'node script.js')"
        blocking_pid="$pid"
        break
      fi
      if [[ "$cmdline" =~ (^|[[:space:]])python3?($|[[:space:]]*$) ]]; then
        blocking="python REPL (use 'python script.py')"
        blocking_pid="$pid"
        break
      fi
    done

    if [[ -n "$blocking" && -n "$blocking_pid" ]]; then
      echo "[$(date '+%H:%M:%S')] 🚨 WATCHDOG: Blocking process detected: $blocking (pid=$blocking_pid)" >> "$activity_log"
      echo "🚨 WATCHDOG: Blocking process detected: $blocking" >&2

      # Also write to errors.log so next iteration sees it.
      {
        echo ""
        echo "## BLOCKED: Interactive Command"
        echo "- **Command**: $blocking"
        echo "- **Action**: Process killed by watchdog"
        echo "- **Fix**: Use non-interactive alternatives (npm init -y, git commit -m \"msg\")"
        echo ""
      } >> "$errors_log" 2>/dev/null || true

      kill -9 "$blocking_pid" 2>/dev/null || true
      echo "GUTTER" > "$fifo" 2>/dev/null || true
      return
    fi
  done
}

# =============================================================================
# LOGGING
# =============================================================================

# Log a message to activity.log
log_activity() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/activity.log"
}

# Log an error to errors.log
log_error() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/errors.log"
}

# Log to progress.md (called by the loop, not the agent)
log_progress() {
  local workspace="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local progress_file="$workspace/.ralph/progress.md"
  
  echo "" >> "$progress_file"
  echo "### $timestamp" >> "$progress_file"
  echo "$message" >> "$progress_file"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize .ralph directory with default files
init_ralph_dir() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  
  # Initialize progress.md if it doesn't exist
  if [[ ! -f "$ralph_dir/progress.md" ]]; then
    cat > "$ralph_dir/progress.md" << 'EOF'
# Progress Log

> Updated by the agent after significant work.

---

## Session History

EOF
  fi
  
  # Initialize guardrails.md if it doesn't exist
  if [[ ! -f "$ralph_dir/guardrails.md" ]]; then
    cat > "$ralph_dir/guardrails.md" << 'EOF'
# Guardrails

> STOP. Read these before every action.

## Non-Interactive Commands Only

**NEVER** run commands that wait for input. Always use flags:
- `npm init -y` (not `npm init`)
- `git commit -m "msg"` (not `git commit`)
- `python script.py` (not `python`)
- `node script.js` (not `node`)

## Safe Workflow

1. **Read before write** - Check file contents before editing
2. **Test after changes** - Run tests to verify
3. **Commit checkpoints** - Save state before risky changes

---

## Learned Failures

_(Added automatically when errors occur)_

EOF
  fi
  
  # Initialize errors.log if it doesn't exist
  if [[ ! -f "$ralph_dir/errors.log" ]]; then
    cat > "$ralph_dir/errors.log" << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF
  fi
  
  # Initialize activity.log if it doesn't exist
  if [[ ! -f "$ralph_dir/activity.log" ]]; then
    cat > "$ralph_dir/activity.log" << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF
  fi
}

# =============================================================================
# TASK MANAGEMENT
# =============================================================================

# Check if task is complete
check_task_complete() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$task_file" ]]; then
    echo "NO_TASK_FILE"
    return
  fi
  
  # Only count actual checkbox list items, not [ ] in prose/examples
  # Matches: "- [ ]", "* [ ]", "1. [ ]", etc.
  local unchecked
  unchecked=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null) || unchecked=0
  
  if [[ "$unchecked" -eq 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$unchecked"
  fi
}

# Count task criteria (returns done:total)
count_criteria() {
  local workspace="${1:-.}"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$task_file" ]]; then
    echo "0:0"
    return
  fi
  
  # Only count actual checkbox list items, not [x] or [ ] in prose/examples
  # Matches: "- [ ]", "* [x]", "1. [ ]", etc.
  local total done_count
  total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total=0
  done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_count=0
  
  echo "$done_count:$total"
}

# =============================================================================
# PROMPT BUILDING
# =============================================================================

# Build the Ralph prompt for an iteration
build_prompt() {
  local workspace="$1"
  local iteration="$2"
  
  # Read guardrails and errors to inject directly
  local guardrails=""
  local errors=""
  if [[ -f "$workspace/.ralph/guardrails.md" ]]; then
    guardrails=$(cat "$workspace/.ralph/guardrails.md")
  fi
  if [[ -f "$workspace/.ralph/errors.log" ]]; then
    errors=$(tail -30 "$workspace/.ralph/errors.log")
  fi
  
  cat << EOF
# Ralph Iteration $iteration

⚠️ **STOP! READ BEFORE ANY ACTION** ⚠️

1. Check if package.json exists BEFORE running npm init
2. This is a git repo - do NOT run git init
3. ALWAYS use: \`npm init -y\` (not \`npm init\`)
4. ALWAYS use: \`git commit -m "msg"\` (not \`git commit\`)

**YOUR FIRST ACTION MUST BE: Read RALPH_TASK.md**

---

$guardrails

## Recent Errors (From Previous Iterations)

$errors

## Read State Files

Before coding:
1. Read \`RALPH_TASK.md\` - your task and completion criteria
2. Read \`.ralph/progress.md\` - what's been accomplished

## Working Directory (Critical)

You are already in a git repository. Work HERE, not in a subdirectory:

- Do NOT run \`git init\` - the repo already exists
- Do NOT run scaffolding commands that create nested directories (\`npx create-*\`)
- Use \`npm init -y\` (with -y flag!) if you need to initialize a Node.js project
- All code should live at the repo root or in subdirectories you create manually

## Git Protocol (Critical)

Ralph's strength is state-in-git, not LLM memory. Commit early and often:

1. After completing each criterion, commit your changes:
   \`git add -A && git commit -m 'ralph: implement state tracker'\`
   \`git add -A && git commit -m 'ralph: fix async race condition'\`
   \`git add -A && git commit -m 'ralph: add CLI adapter with commander'\`
   Always describe what you actually did - never use placeholders like '<description>'
2. After any significant code change (even partial): commit with descriptive message
3. Before any risky refactor: commit current state as checkpoint
4. Push after every 2-3 commits: \`git push\`

If you get rotated, the next agent picks up from your last commit. Your commits ARE your memory.

## Task Execution

1. Work on the next unchecked criterion in RALPH_TASK.md (look for \`[ ]\`)
2. Run tests after changes (check RALPH_TASK.md for test_command)
3. **Mark completed criteria**: Edit RALPH_TASK.md and change \`[ ]\` to \`[x]\`
   - Example: \`- [ ] Implement parser\` becomes \`- [x] Implement parser\`
   - This is how progress is tracked - YOU MUST update the file
4. Update \`.ralph/progress.md\` with what you accomplished
5. When ALL criteria show \`[x]\`: output \`<ralph>COMPLETE</ralph>\`
6. If stuck 3+ times on same issue: output \`<ralph>GUTTER</ralph>\`

## Learning from Failures

When something fails:
1. Check \`.ralph/errors.log\` for what went wrong
2. Add a one-line fix to \`.ralph/guardrails.md\` under "Learned Failures":
   \`- [what went wrong] → [what to do instead]\`

## Context Rotation Warning

You may receive a warning that context is running low. When you see it:
1. Finish your current file edit
2. Commit and push your changes
3. Update .ralph/progress.md with what you accomplished and what's next
4. You will be rotated to a fresh agent that continues your work

Begin by reading the state files.
EOF
}

# =============================================================================
# SPINNER
# =============================================================================

# Spinner to show the loop is alive (not frozen)
# Outputs to stderr so it's not captured by $()
spinner() {
  local workspace="$1"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while true; do
    # Avoid line-wrapping (which creates "repeated" lines) by:
    # - clearing the line every frame
    # - showing a short, relative watch command
    # - truncating to terminal width
    local cols msg
    cols="$(tput cols 2>/dev/null || echo 80)"
    msg="  🐛 Agent working... ${spin:i++%${#spin}:1}  (watch: tail -f .ralph/activity.log)"
    if [[ "$cols" =~ ^[0-9]+$ ]] && (( ${#msg} >= cols )); then
      msg="${msg:0:cols-1}"
    fi
    printf "\r\033[2K%s" "$msg" >&2
    sleep 0.1
  done
}

# =============================================================================
# ITERATION RUNNER
# =============================================================================

# Run a single agent iteration
# Returns: signal (ROTATE, GUTTER, COMPLETE, or empty)
run_iteration() {
  local workspace="$1"
  local iteration="$2"
  local session_id="${3:-}"
  local script_dir="${4:-$(dirname "${BASH_SOURCE[0]}")}"
  
  local prompt=$(build_prompt "$workspace" "$iteration")
  local fifo="$workspace/.ralph/.parser_fifo"
  
  # Create named pipe for parser signals
  rm -f "$fifo"
  mkfifo "$fifo"
  
  # Use stderr for display (stdout is captured for signal)
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "🐛 Ralph Iteration $iteration" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Workspace: $workspace" >&2
  echo "Model:     $MODEL" >&2
  echo "Monitor:   tail -f $workspace/.ralph/activity.log" >&2
  echo "" >&2
  
  # Log session start to progress.md
  log_progress "$workspace" "**Session $iteration started** (model: $MODEL)"
  
  # Build cursor-agent command
  local cmd="cursor-agent -p --force --output-format stream-json --model $MODEL"
  
  if [[ -n "$session_id" ]]; then
    echo "Resuming session: $session_id" >&2
    cmd="$cmd --resume=\"$session_id\""
  fi
  
  # Change to workspace
  cd "$workspace"
  
  # Start spinner to show we're alive
  spinner "$workspace" &
  local spinner_pid=$!
  
  # Start parser in background, reading from cursor-agent
  # Parser outputs to fifo, we read signals from fifo
  (
    # Harden the execution environment against interactive commands.
    # Also prepend shimmed binaries so calls like `npm init` cannot block.
    export PATH="$script_dir/shims:$PATH"
    export CI=1
    export npm_config_yes=true
    export npm_config_audit=false
    export npm_config_fund=false
    export GIT_TERMINAL_PROMPT=0
    export GIT_EDITOR=:
    export EDITOR=:
    export PAGER=cat
    eval "$cmd \"$prompt\"" 2>&1 | "$script_dir/stream-parser.sh" "$workspace" > "$fifo"
  ) &
  local agent_pid=$!

  # Start watchdog to catch blocking interactive commands (e.g. npm init)
  run_watchdog "$agent_pid" "$fifo" "$workspace" &
  local watchdog_pid=$!
  
  # Read signals from parser
  local signal=""
  while IFS= read -r line; do
    case "$line" in
      "ROTATE")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "🔄 Context rotation triggered - stopping agent..." >&2
        kill_tree $agent_pid
        signal="ROTATE"
        break
        ;;
      "WARN")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "⚠️  Context warning - agent should wrap up soon..." >&2
        # Send interrupt to encourage wrap-up (agent continues but is notified)
        ;;
      "GUTTER")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "🚨 Gutter detected - killing stuck agent..." >&2
        kill_tree $agent_pid
        signal="GUTTER"
        break
        ;;
      "COMPLETE")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "✅ Agent signaled completion!" >&2
        kill_tree $agent_pid
        signal="COMPLETE"
        break
        ;;
    esac
  done < "$fifo"
  
  # Wait for agent to finish
  wait $agent_pid 2>/dev/null || true

  # Stop watchdog
  kill $watchdog_pid 2>/dev/null || true
  wait $watchdog_pid 2>/dev/null || true
  
  # Stop spinner and clear line
  kill_tree $spinner_pid
  wait $spinner_pid 2>/dev/null || true
  printf "\r\033[K" >&2  # Clear spinner line
  
  # Cleanup
  rm -f "$fifo"
  
  echo "$signal"
}

# =============================================================================
# MAIN LOOP
# =============================================================================

# Run the main Ralph loop
# Args: workspace
# Uses global: MAX_ITERATIONS, MODEL, USE_BRANCH, OPEN_PR
run_ralph_loop() {
  local workspace="$1"
  local script_dir="${2:-$(dirname "${BASH_SOURCE[0]}")}"
  
  # Commit any uncommitted work first
  cd "$workspace"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: initial commit before loop" || true
  fi
  
  # Create branch if requested
  if [[ -n "$USE_BRANCH" ]]; then
    echo "🌿 Creating branch: $USE_BRANCH"
    git checkout -b "$USE_BRANCH" 2>/dev/null || git checkout "$USE_BRANCH"
  fi
  
  echo ""
  echo "🚀 Starting Ralph loop..."
  echo ""
  
  # Main loop
  local iteration=1
  local session_id=""
  
  while [[ $iteration -le $MAX_ITERATIONS ]]; do
    # Run iteration
    local signal
    signal=$(run_iteration "$workspace" "$iteration" "$session_id" "$script_dir")
    
    # Check task completion
    local task_status
    task_status=$(check_task_complete "$workspace")
    
    if [[ "$task_status" == "COMPLETE" ]]; then
      log_progress "$workspace" "**Session $iteration ended** - ✅ TASK COMPLETE"
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "🎉 RALPH COMPLETE! All criteria satisfied."
      echo "═══════════════════════════════════════════════════════════════════"
      echo ""
      echo "Completed in $iteration iteration(s)."
      echo "Check git log for detailed history."
      
      # Open PR if requested
      if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
        echo ""
        echo "📝 Opening pull request..."
        git push -u origin "$USE_BRANCH" 2>/dev/null || git push
        if command -v gh &> /dev/null; then
          gh pr create --fill || echo "⚠️  Could not create PR automatically. Create manually."
        else
          echo "⚠️  gh CLI not found. Push complete, create PR manually."
        fi
      fi
      
      return 0
    fi
    
    # Handle signals
    case "$signal" in
      "COMPLETE")
        # Agent signaled completion - verify with checkbox check
        if [[ "$task_status" == "COMPLETE" ]]; then
          log_progress "$workspace" "**Session $iteration ended** - ✅ TASK COMPLETE (agent signaled)"
          echo ""
          echo "═══════════════════════════════════════════════════════════════════"
          echo "🎉 RALPH COMPLETE! Agent signaled completion and all criteria verified."
          echo "═══════════════════════════════════════════════════════════════════"
          echo ""
          echo "Completed in $iteration iteration(s)."
          echo "Check git log for detailed history."
          
          # Open PR if requested
          if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
            echo ""
            echo "📝 Opening pull request..."
            git push -u origin "$USE_BRANCH" 2>/dev/null || git push
            if command -v gh &> /dev/null; then
              gh pr create --fill || echo "⚠️  Could not create PR automatically. Create manually."
            else
              echo "⚠️  gh CLI not found. Push complete, create PR manually."
            fi
          fi
          
          return 0
        else
          # Agent said complete but checkboxes say otherwise - continue
          log_progress "$workspace" "**Session $iteration ended** - Agent signaled complete but criteria remain"
          echo ""
          echo "⚠️  Agent signaled completion but unchecked criteria remain."
          echo "   Continuing with next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
      "ROTATE")
        log_progress "$workspace" "**Session $iteration ended** - 🔄 Context rotation (token limit reached)"
        echo ""
        echo "🔄 Rotating to fresh context..."
        iteration=$((iteration + 1))
        session_id=""
        ;;
      "GUTTER")
        log_progress "$workspace" "**Session $iteration ended** - 🚨 GUTTER (agent stuck)"
        echo ""
        echo "🚨 Gutter detected. Check .ralph/errors.log for details."
        echo "   The agent may be stuck. Consider:"
        echo "   1. Check .ralph/guardrails.md for lessons"
        echo "   2. Manually fix the blocking issue"
        echo "   3. Re-run the loop"
        return 1
        ;;
      *)
        # Agent finished naturally, check if more work needed
        if [[ "$task_status" == INCOMPLETE:* ]]; then
          local remaining_count=${task_status#INCOMPLETE:}
          log_progress "$workspace" "**Session $iteration ended** - Agent finished naturally ($remaining_count criteria remaining)"
          echo ""
          echo "📋 Agent finished but $remaining_count criteria remaining."
          echo "   Starting next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
    esac
    
    # Brief pause between iterations
    sleep 2
  done
  
  log_progress "$workspace" "**Loop ended** - ⚠️ Max iterations ($MAX_ITERATIONS) reached"
  echo ""
  echo "⚠️  Max iterations ($MAX_ITERATIONS) reached."
  echo "   Task may not be complete. Check progress manually."
  return 1
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

# Check all prerequisites, exit with error message if any fail
check_prerequisites() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Check for task file
  if [[ ! -f "$task_file" ]]; then
    echo "❌ No RALPH_TASK.md found in $workspace"
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
    return 1
  fi
  
  # Check for cursor-agent CLI
  if ! command -v cursor-agent &> /dev/null; then
    echo "❌ cursor-agent CLI not found"
    echo ""
    echo "Install via:"
    echo "  curl https://cursor.com/install -fsS | bash"
    return 1
  fi
  
  # Check for git repo
  if ! git -C "$workspace" rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not a git repository"
    echo "   Ralph requires git for state persistence."
    return 1
  fi
  
  return 0
}

# =============================================================================
# DISPLAY HELPERS
# =============================================================================

# Show task summary
show_task_summary() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  
  # Count criteria - only actual checkbox list items (- [ ], * [x], 1. [ ], etc.)
  local total_criteria done_criteria remaining
  total_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total_criteria=0
  done_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_criteria=0
  remaining=$((total_criteria - done_criteria))
  
  echo "Progress: $done_criteria / $total_criteria criteria complete ($remaining remaining)"
  echo "Model:    $MODEL"
  echo ""
  
  # Return remaining count for caller to check
  echo "$remaining"
}

# Show Ralph banner
show_banner() {
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: Autonomous Development Loop"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  \"That's the beauty of Ralph - the technique is deterministically"
  echo "   bad in an undeterministic world.\""
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
}
