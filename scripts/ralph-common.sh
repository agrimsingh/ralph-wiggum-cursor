#!/bin/bash
# Ralph Wiggum: Common utilities and loop logic
#
# Shared functions for ralph-loop.sh and ralph-setup.sh
# All state lives in .ralph/runs/<runId>/ within the project.
#
# Supports multiple task files running in parallel via isolated run directories.

# =============================================================================
# CONFIGURATION (can be overridden before sourcing or via environment)
# =============================================================================

# Token thresholds
WARN_THRESHOLD="${WARN_THRESHOLD:-70000}"
ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-80000}"

# Iteration limits
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"

# Model selection
DEFAULT_MODEL="opus-4.5-thinking"
MODEL="${RALPH_MODEL:-$DEFAULT_MODEL}"

# Task file (default: RALPH_TASK.md)
TASK_FILE="${RALPH_TASK_FILE:-RALPH_TASK.md}"

# Run ID (if not set, derived from task file path)
RUN_ID="${RALPH_RUN_ID:-}"

# Feature flags (set by caller)
USE_BRANCH="${USE_BRANCH:-}"
OPEN_PR="${OPEN_PR:-false}"
SKIP_CONFIRM="${SKIP_CONFIRM:-false}"

# =============================================================================
# RUN ID & DIRECTORY HELPERS
# =============================================================================

# Derive a stable run ID from a task file path
# Uses first 8 chars of sha1 hash of the relative path
derive_run_id() {
  local task_file="$1"
  local workspace="${2:-.}"
  
  # Get relative path from workspace
  local rel_path
  if [[ "$task_file" == /* ]]; then
    # Absolute path - make relative to workspace
    rel_path="${task_file#$workspace/}"
  else
    rel_path="$task_file"
  fi
  
  # Hash the relative path and take first 8 chars
  if command -v sha1sum &> /dev/null; then
    echo -n "$rel_path" | sha1sum | cut -c1-8
  elif command -v shasum &> /dev/null; then
    echo -n "$rel_path" | shasum -a 1 | cut -c1-8
  else
    # Fallback: use md5 or simple hash
    echo -n "$rel_path" | md5 2>/dev/null | cut -c1-8 || echo "default"
  fi
}

# Get the run directory for a given run ID
# Returns: workspace/.ralph/runs/<run_id>
get_run_dir() {
  local workspace="${1:-.}"
  local run_id="$2"
  
  if [[ -z "$run_id" ]]; then
    echo "ERROR: run_id required" >&2
    return 1
  fi
  
  echo "$workspace/.ralph/runs/$run_id"
}

# Resolve task file path (handles relative and absolute paths)
resolve_task_file() {
  local workspace="$1"
  local task_file_arg="$2"
  
  if [[ -z "$task_file_arg" ]]; then
    task_file_arg="$TASK_FILE"
  fi
  
  if [[ "$task_file_arg" == /* ]]; then
    # Absolute path
    echo "$task_file_arg"
  else
    # Relative to workspace
    echo "$workspace/$task_file_arg"
  fi
}

# Initialize a run directory with default state files
init_run_dir() {
  local run_dir="$1"
  
  mkdir -p "$run_dir"
  
  # Initialize progress.md if it doesn't exist
  if [[ ! -f "$run_dir/progress.md" ]]; then
    cat > "$run_dir/progress.md" << 'EOF'
# Progress Log

> Updated by the agent after significant work.

---

## Session History

EOF
  fi
  
  # Initialize errors.log if it doesn't exist
  if [[ ! -f "$run_dir/errors.log" ]]; then
    cat > "$run_dir/errors.log" << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF
  fi
  
  # Initialize activity.log if it doesn't exist
  if [[ ! -f "$run_dir/activity.log" ]]; then
    cat > "$run_dir/activity.log" << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF
  fi
  
  # Initialize iteration counter
  if [[ ! -f "$run_dir/.iteration" ]]; then
    echo "0" > "$run_dir/.iteration"
  fi
}

# Initialize the shared guardrails.md (lives at .ralph/guardrails.md, shared across runs)
init_guardrails() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  
  if [[ ! -f "$ralph_dir/guardrails.md" ]]; then
    cat > "$ralph_dir/guardrails.md" << 'EOF'
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

EOF
  fi
}

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

# Get current iteration from run_dir/.iteration
get_iteration() {
  local run_dir="$1"
  local state_file="$run_dir/.iteration"
  
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo "0"
  fi
}

# Set iteration number
set_iteration() {
  local run_dir="$1"
  local iteration="$2"
  
  mkdir -p "$run_dir"
  echo "$iteration" > "$run_dir/.iteration"
}

# Increment iteration and return new value
increment_iteration() {
  local run_dir="$1"
  local current=$(get_iteration "$run_dir")
  local next=$((current + 1))
  set_iteration "$run_dir" "$next"
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

# =============================================================================
# LOGGING (now uses run_dir)
# =============================================================================

# Log a message to activity.log
log_activity() {
  local run_dir="$1"
  local message="$2"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$run_dir"
  echo "[$timestamp] $message" >> "$run_dir/activity.log"
}

# Log an error to errors.log
log_error() {
  local run_dir="$1"
  local message="$2"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$run_dir"
  echo "[$timestamp] $message" >> "$run_dir/errors.log"
}

# Log to progress.md (called by the loop, not the agent)
log_progress() {
  local run_dir="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local progress_file="$run_dir/progress.md"
  
  mkdir -p "$run_dir"
  echo "" >> "$progress_file"
  echo "### $timestamp" >> "$progress_file"
  echo "$message" >> "$progress_file"
}

# =============================================================================
# BEADS HELPERS
# =============================================================================

# Get the Beads label for a run (stored in run_dir/beads.label)
get_beads_label() {
  local run_dir="$1"
  local label_file="$run_dir/beads.label"
  
  if [[ -f "$label_file" ]]; then
    cat "$label_file"
  else
    echo ""
  fi
}

# Set/store the Beads label for a run
set_beads_label() {
  local run_dir="$1"
  local label="$2"
  
  mkdir -p "$run_dir"
  echo "$label" > "$run_dir/beads.label"
}

# Get the root epic ID for a run (stored in run_dir/beads.root_id)
get_beads_root_id() {
  local run_dir="$1"
  local root_file="$run_dir/beads.root_id"
  
  if [[ -f "$root_file" ]]; then
    cat "$root_file"
  else
    echo ""
  fi
}

# Set/store the root epic ID for a run
set_beads_root_id() {
  local run_dir="$1"
  local root_id="$2"
  
  mkdir -p "$run_dir"
  echo "$root_id" > "$run_dir/beads.root_id"
}

# Check if Beads is initialized for a run
is_beads_initialized() {
  local run_dir="$1"
  
  [[ -f "$run_dir/beads.label" ]] && [[ -f "$run_dir/beads.root_id" ]]
}

# Parse task title from task file frontmatter or first heading
parse_task_title() {
  local task_file="$1"
  
  # Try to get from frontmatter 'task:' field
  local title
  title=$(grep -m1 '^task:' "$task_file" 2>/dev/null | sed 's/^task:[[:space:]]*//' | tr -d '"')
  
  if [[ -n "$title" ]]; then
    echo "$title"
    return
  fi
  
  # Fall back to first markdown heading
  title=$(grep -m1 '^#[^#]' "$task_file" 2>/dev/null | sed 's/^#[[:space:]]*//')
  
  if [[ -n "$title" ]]; then
    echo "$title"
    return
  fi
  
  # Last resort: use filename
  basename "$task_file" .md
}

# Parse success criteria from task file
# Returns one criterion per line
parse_success_criteria() {
  local task_file="$1"
  
  # Extract lines that look like criteria (numbered or dash list items)
  # Look for lines after "Success Criteria" heading
  local in_criteria=false
  while IFS= read -r line; do
    # Check if we're entering the Success Criteria section
    if [[ "$line" =~ ^##.*[Ss]uccess.*[Cc]riteria ]]; then
      in_criteria=true
      continue
    fi
    
    # Check if we're leaving the section (next heading)
    if [[ "$in_criteria" == "true" ]] && [[ "$line" =~ ^## ]]; then
      break
    fi
    
    # If in criteria section, extract list items
    if [[ "$in_criteria" == "true" ]]; then
      # Match numbered items: "1. Something" or "1. [ ] Something"
      if [[ "$line" =~ ^[[:space:]]*[0-9]+\.[[:space:]]+(.*) ]]; then
        local item="${BASH_REMATCH[1]}"
        # Strip checkbox if present
        item=$(echo "$item" | sed 's/^\[[x ]\][[:space:]]*//')
        if [[ -n "$item" ]]; then
          echo "$item"
        fi
      # Match dash/asterisk items: "- Something" or "- [ ] Something"
      elif [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+(.*) ]]; then
        local item="${BASH_REMATCH[1]}"
        # Strip checkbox if present
        item=$(echo "$item" | sed 's/^\[[x ]\][[:space:]]*//')
        if [[ -n "$item" ]]; then
          echo "$item"
        fi
      fi
    fi
  done < "$task_file"
}

# Bootstrap Beads issues from a task file
# Creates a root epic and child tasks for each success criterion
bootstrap_beads_from_task_md() {
  local workspace="$1"
  local task_file="$2"
  local run_dir="$3"
  local run_id="$4"
  
  # Check if already bootstrapped
  if is_beads_initialized "$run_dir"; then
    echo "Beads already initialized for this run" >&2
    return 0
  fi
  
  # Check bd is available
  if ! command -v bd &> /dev/null; then
    echo "ERROR: bd (Beads) CLI not found. Cannot bootstrap issues." >&2
    return 1
  fi
  
  local label="ralph:$run_id"
  local task_title
  task_title=$(parse_task_title "$task_file")
  
  echo "🔮 Bootstrapping Beads issues from $task_file..." >&2
  echo "   Label: $label" >&2
  echo "   Title: $task_title" >&2
  
  # Create root epic
  local epic_result
  epic_result=$(bd create "Ralph: $task_title" -t epic -p 1 -l "$label" --json 2>/dev/null)
  
  if [[ $? -ne 0 ]] || [[ -z "$epic_result" ]]; then
    echo "ERROR: Failed to create root epic" >&2
    return 1
  fi
  
  local root_id
  root_id=$(echo "$epic_result" | jq -r '.id // .issue.id // empty' 2>/dev/null)
  
  if [[ -z "$root_id" ]]; then
    echo "ERROR: Could not extract root epic ID from response" >&2
    return 1
  fi
  
  echo "   Root epic: $root_id" >&2
  
  # Store label and root ID
  set_beads_label "$run_dir" "$label"
  set_beads_root_id "$run_dir" "$root_id"
  
  # Parse and create child tasks
  local criteria_count=0
  while IFS= read -r criterion; do
    if [[ -n "$criterion" ]]; then
      ((criteria_count++))
      echo "   Creating task: $criterion" >&2
      bd create "$criterion" -t task -p 2 -l "$label" --parent "$root_id" --json >/dev/null 2>&1
    fi
  done < <(parse_success_criteria "$task_file")
  
  echo "✅ Created $criteria_count tasks under epic $root_id" >&2
  
  # Sync to ensure everything is persisted
  bd sync >/dev/null 2>&1 || true
  
  return 0
}

# =============================================================================
# TASK MANAGEMENT (Beads-based)
# =============================================================================

# Check if task is complete (Beads-based)
# Returns: COMPLETE, INCOMPLETE:<count>, or NO_BEADS
check_task_complete() {
  local run_dir="$1"
  
  local label
  label=$(get_beads_label "$run_dir")
  
  if [[ -z "$label" ]]; then
    echo "NO_BEADS"
    return
  fi
  
  # Check for any non-closed issues with this label
  # Statuses that mean "not done": open, in_progress, blocked, deferred
  local open_count=0
  
  for status in open in_progress blocked deferred; do
    local count
    count=$(bd list --label "$label" --status "$status" --json 2>/dev/null | jq 'length' 2>/dev/null) || count=0
    open_count=$((open_count + count))
  done
  
  if [[ "$open_count" -eq 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$open_count"
  fi
}

# Count task criteria (Beads-based)
# Returns: done:total
count_criteria() {
  local run_dir="$1"
  
  local label
  label=$(get_beads_label "$run_dir")
  
  if [[ -z "$label" ]]; then
    echo "0:0"
    return
  fi
  
  # Total = all issues with label (excluding the epic itself by type)
  local total
  total=$(bd list --label "$label" --type task --json 2>/dev/null | jq 'length' 2>/dev/null) || total=0
  
  # Done = closed issues with label
  local done_count
  done_count=$(bd list --label "$label" --type task --status closed --json 2>/dev/null | jq 'length' 2>/dev/null) || done_count=0
  
  echo "$done_count:$total"
}

# =============================================================================
# PROMPT BUILDING (Beads-based)
# =============================================================================

# Build the Ralph prompt for an iteration
build_prompt() {
  local workspace="$1"
  local iteration="$2"
  local task_file="$3"
  local run_dir="$4"
  
  local label
  label=$(get_beads_label "$run_dir")
  
  local root_id
  root_id=$(get_beads_root_id "$run_dir")
  
  # Get relative paths for display
  local rel_task_file="${task_file#$workspace/}"
  local rel_run_dir="${run_dir#$workspace/}"
  
  cat << EOF
# Ralph Iteration $iteration

You are an autonomous development agent using the Ralph methodology with Beads task tracking.

## FIRST: Read State Files

Before doing anything:
1. Read \`$rel_task_file\` - your task overview and context
2. Read \`.ralph/guardrails.md\` - lessons from past failures (FOLLOW THESE)
3. Read \`$rel_run_dir/progress.md\` - what's been accomplished
4. Read \`$rel_run_dir/errors.log\` - recent failures to avoid

## Beads Task Tracking

This run uses Beads for task management. Your tasks are labeled with \`$label\`.

**Find your next task:**
\`\`\`bash
bd ready --label $label --json
\`\`\`

**Claim a task before working on it:**
\`\`\`bash
bd update <task-id> --status in_progress --json
\`\`\`

**Close a task when done:**
\`\`\`bash
bd close <task-id> --reason "Brief description of what was done" --json
\`\`\`

**Sync at end of work:**
\`\`\`bash
bd sync
\`\`\`

## Working Directory (Critical)

You are already in a git repository. Work HERE, not in a subdirectory:

- Do NOT run \`git init\` - the repo already exists
- Do NOT run scaffolding commands that create nested directories (\`npx create-*\`, \`npm init\`, etc.)
- If you need to scaffold, use flags like \`--no-git\` or scaffold into the current directory (\`.\`)
- All code should live at the repo root or in subdirectories you create manually

## Git Protocol (Critical)

Ralph's strength is state-in-git, not LLM memory. Commit early and often:

1. After completing each task, commit your changes:
   \`git add -A && git commit -m 'ralph: implement state tracker'\`
   \`git add -A && git commit -m 'ralph: fix async race condition'\`
   Always describe what you actually did - never use placeholders like '<description>'
2. After any significant code change (even partial): commit with descriptive message
3. Before any risky refactor: commit current state as checkpoint
4. Push after every 2-3 commits: \`git push\`

If you get rotated, the next agent picks up from your last commit. Your commits ARE your memory.

## Task Execution Workflow

1. Run \`bd ready --label $label --json\` to find the next available task
2. Claim it: \`bd update <id> --status in_progress --json\`
3. Work on the task (check $rel_task_file for test_command if applicable)
4. Close when done: \`bd close <id> --reason "description" --json\`
5. Update \`$rel_run_dir/progress.md\` with what you accomplished
6. Sync: \`bd sync\`
7. Repeat until no tasks remain

## Completion

When \`bd ready --label $label --json\` returns an empty list AND all tasks are closed:
- Output: \`<ralph>COMPLETE</ralph>\`

If stuck 3+ times on the same issue:
- Output: \`<ralph>GUTTER</ralph>\`

## Learning from Failures

When something fails:
1. Check \`$rel_run_dir/errors.log\` for failure history
2. Figure out the root cause
3. Add a Sign to \`.ralph/guardrails.md\` using this format:

\`\`\`
### Sign: [Descriptive Name]
- **Trigger**: When this situation occurs
- **Instruction**: What to do instead
- **Added after**: Iteration $iteration - what happened
\`\`\`

## Context Rotation Warning

You may receive a warning that context is running low. When you see it:
1. Finish your current file edit
2. Commit and push your changes
3. Run \`bd sync\` to persist task state
4. Update $rel_run_dir/progress.md with what you accomplished and what's next
5. You will be rotated to a fresh agent that continues your work

Begin by reading the state files, then find your next task with \`bd ready --label $label --json\`.
EOF
}

# =============================================================================
# SPINNER
# =============================================================================

# Spinner to show the loop is alive (not frozen)
# Outputs to stderr so it's not captured by $()
spinner() {
  local run_dir="$1"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while true; do
    printf "\r  🐛 Agent working... %s  (watch: tail -f %s/activity.log)" "${spin:i++%${#spin}:1}" "$run_dir" >&2
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
  local task_file="$5"
  local run_dir="$6"
  
  local prompt=$(build_prompt "$workspace" "$iteration" "$task_file" "$run_dir")
  local fifo="$run_dir/.parser_fifo"
  
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
  echo "Task file: $task_file" >&2
  echo "Run dir:   $run_dir" >&2
  echo "Model:     $MODEL" >&2
  echo "Monitor:   tail -f $run_dir/activity.log" >&2
  echo "" >&2
  
  # Log session start to progress.md
  log_progress "$run_dir" "**Session $iteration started** (model: $MODEL)"
  
  # Build cursor-agent command
  local cmd="cursor-agent -p --force --output-format stream-json --model $MODEL"
  
  if [[ -n "$session_id" ]]; then
    echo "Resuming session: $session_id" >&2
    cmd="$cmd --resume=\"$session_id\""
  fi
  
  # Change to workspace
  cd "$workspace"
  
  # Start spinner to show we're alive
  spinner "$run_dir" &
  local spinner_pid=$!
  
  # Start parser in background, reading from cursor-agent
  # Parser outputs to fifo, we read signals from fifo
  (
    eval "$cmd \"$prompt\"" 2>&1 | "$script_dir/stream-parser.sh" "$workspace" "$run_dir" > "$fifo"
  ) &
  local agent_pid=$!
  
  # Read signals from parser
  local signal=""
  while IFS= read -r line; do
    case "$line" in
      "ROTATE")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "🔄 Context rotation triggered - stopping agent..." >&2
        kill $agent_pid 2>/dev/null || true
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
        echo "🚨 Gutter detected - agent may be stuck..." >&2
        signal="GUTTER"
        # Don't kill yet, let agent try to recover
        ;;
      "COMPLETE")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "✅ Agent signaled completion!" >&2
        signal="COMPLETE"
        # Let agent finish gracefully
        ;;
    esac
  done < "$fifo"
  
  # Wait for agent to finish
  wait $agent_pid 2>/dev/null || true
  
  # Stop spinner and clear line
  kill $spinner_pid 2>/dev/null || true
  wait $spinner_pid 2>/dev/null || true
  printf "\r\033[K" >&2  # Clear spinner line
  
  # Cleanup
  rm -f "$fifo"
  
  # Sync Beads after iteration
  bd sync >/dev/null 2>&1 || true
  
  echo "$signal"
}

# =============================================================================
# MAIN LOOP
# =============================================================================

# Run the main Ralph loop
# Args: workspace, script_dir, task_file, run_dir
# Uses global: MAX_ITERATIONS, MODEL, USE_BRANCH, OPEN_PR
run_ralph_loop() {
  local workspace="$1"
  local script_dir="${2:-$(dirname "${BASH_SOURCE[0]}")}"
  local task_file="$3"
  local run_dir="$4"
  
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
    signal=$(run_iteration "$workspace" "$iteration" "$session_id" "$script_dir" "$task_file" "$run_dir")
    
    # Check task completion via Beads
    local task_status
    task_status=$(check_task_complete "$run_dir")
    
    if [[ "$task_status" == "COMPLETE" ]]; then
      log_progress "$run_dir" "**Session $iteration ended** - ✅ TASK COMPLETE"
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "🎉 RALPH COMPLETE! All Beads tasks satisfied."
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
        # Agent signaled completion - verify with Beads check
        if [[ "$task_status" == "COMPLETE" ]]; then
          log_progress "$run_dir" "**Session $iteration ended** - ✅ TASK COMPLETE (agent signaled)"
          echo ""
          echo "═══════════════════════════════════════════════════════════════════"
          echo "🎉 RALPH COMPLETE! Agent signaled completion and all tasks verified."
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
          # Agent said complete but Beads says otherwise - continue
          log_progress "$run_dir" "**Session $iteration ended** - Agent signaled complete but tasks remain"
          echo ""
          echo "⚠️  Agent signaled completion but open tasks remain."
          echo "   Continuing with next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
      "ROTATE")
        log_progress "$run_dir" "**Session $iteration ended** - 🔄 Context rotation (token limit reached)"
        echo ""
        echo "🔄 Rotating to fresh context..."
        iteration=$((iteration + 1))
        session_id=""
        ;;
      "GUTTER")
        log_progress "$run_dir" "**Session $iteration ended** - 🚨 GUTTER (agent stuck)"
        echo ""
        echo "🚨 Gutter detected. Check $run_dir/errors.log for details."
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
          log_progress "$run_dir" "**Session $iteration ended** - Agent finished naturally ($remaining_count tasks remaining)"
          echo ""
          echo "📋 Agent finished but $remaining_count tasks remaining."
          echo "   Starting next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
    esac
    
    # Brief pause between iterations
    sleep 2
  done
  
  log_progress "$run_dir" "**Loop ended** - ⚠️ Max iterations ($MAX_ITERATIONS) reached"
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
  local task_file="$2"
  
  # Check for task file
  if [[ ! -f "$task_file" ]]; then
    echo "❌ Task file not found: $task_file"
    echo ""
    echo "Create a task file first, or specify one with --task-file"
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
  
  # Check for bd (Beads) CLI
  if ! command -v bd &> /dev/null; then
    echo "❌ bd (Beads) CLI not found"
    echo ""
    echo "Ralph requires Beads for task tracking. Install via:"
    echo ""
    echo "  # Option 1: curl installer"
    echo "  curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash"
    echo ""
    echo "  # Option 2: Homebrew"
    echo "  brew install steveyegge/beads/bd"
    echo ""
    echo "  # Option 3: npm"
    echo "  npm install -g @beads/bd"
    echo ""
    echo "Then run: bd init --stealth --quiet"
    return 1
  fi
  
  # Check if Beads is initialized in this repo
  if ! bd info --json &>/dev/null; then
    echo "❌ Beads not initialized in this repository"
    echo ""
    echo "Run: bd init --stealth --quiet"
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

# Show task summary (Beads-based)
show_task_summary() {
  local task_file="$1"
  local run_dir="$2"
  
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
