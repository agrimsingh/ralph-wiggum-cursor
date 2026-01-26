#!/bin/bash
# Ralph Wiggum: Parallel Execution with Git Worktrees
#
# Runs multiple agents concurrently, each in an isolated git worktree.
# After completion, merges branches back to base.
#
# Usage:
#   source ralph-parallel.sh
#   run_parallel_tasks "$workspace" "$max_parallel"

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

WORKTREE_BASE_DIR=".ralph-worktrees"
PARALLEL_STATE_DIR=".ralph/parallel"
PARALLEL_LOCK_DIR=".ralph/locks/parallel.lock"

MAX_PARALLEL="${MAX_PARALLEL:-3}"
SKIP_MERGE="${SKIP_MERGE:-false}"
CREATE_PR="${CREATE_PR:-false}"

# =============================================================================
# WORKTREE MANAGEMENT
# =============================================================================

# Check if worktrees are usable (not already in a worktree)
can_use_worktrees() {
  local workspace="${1:-.}"
  local git_path="$workspace/.git"
  
  # If .git is a file (linked worktree), we can't nest worktrees
  if [[ -f "$git_path" ]]; then
    return 1
  fi
  
  # Check if .git directory exists
  [[ -d "$git_path" ]]
}

# Get worktree base directory
get_worktree_base() {
  local workspace="${1:-.}"
  local base="$workspace/$WORKTREE_BASE_DIR"
  mkdir -p "$base"
  echo "$base"
}

# Generate unique ID for branch names
generate_unique_id() {
  echo "$(date +%s)-$(head -c 4 /dev/urandom | xxd -p)"
}

# Slugify text for branch names
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-|-$//g' | cut -c1-40
}

# Acquire a lock so parallel runs don't overlap.
# Uses an atomic mkdir lock directory for portability.
acquire_parallel_lock() {
  local workspace="${1:-.}"
  local lock_dir="$workspace/$PARALLEL_LOCK_DIR"
  local lock_parent
  lock_parent="$(dirname "$lock_dir")"

  mkdir -p "$lock_parent"

  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" > "$lock_dir/pid" 2>/dev/null || true
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$lock_dir/created_at" 2>/dev/null || true
    trap 'rm -rf "'"$lock_dir"'" 2>/dev/null || true' EXIT INT TERM
    return 0
  fi

  echo "❌ Parallel lock already held: $lock_dir" >&2
  if [[ -f "$lock_dir/pid" ]]; then
    echo "   pid: $(cat "$lock_dir/pid" 2>/dev/null || true)" >&2
  fi
  if [[ -f "$lock_dir/created_at" ]]; then
    echo "   created_at: $(cat "$lock_dir/created_at" 2>/dev/null || true)" >&2
  fi
  echo "   If you're sure no run is active, delete: rm -rf \"$lock_dir\"" >&2
  return 1
}

init_parallel_run_dir() {
  local workspace="${1:-.}"
  local run_id="$2"
  local run_dir="$workspace/$PARALLEL_STATE_DIR/$run_id"
  mkdir -p "$run_dir"
  echo "$run_dir"
}

# Create a worktree for an agent
# Uses globals: RUN_ID, BASE_SHA
# Args: task_id, task_name, job_id, worktree_base, original_dir
# Returns: worktree_dir|branch_name
create_agent_worktree() {
  local task_id="$1"
  local task_name="$2"
  local job_id="$3"
  local worktree_base="$4"
  local original_dir="$5"

  if [[ -z "${RUN_ID:-}" ]] || [[ -z "${BASE_SHA:-}" ]]; then
    echo "ERROR: RUN_ID/BASE_SHA not set (internal)" >&2
    return 1
  fi

  local branch_name="ralph/parallel-${RUN_ID}-${job_id}-${task_id}-$(slugify "$task_name")"
  local worktree_dir="$worktree_base/${RUN_ID}-${job_id}"
  
  # Remove existing worktree dir if any
  if [[ -d "$worktree_dir" ]]; then
    rm -rf "$worktree_dir"
    git -C "$original_dir" worktree prune 2>/dev/null || true
  fi
  
  # Create worktree with new branch
  git -C "$original_dir" worktree add -B "$branch_name" "$worktree_dir" "$BASE_SHA" >/dev/null 2>&1
  
  echo "$worktree_dir|$branch_name"
}

# Cleanup a worktree after agent completes
# Args: worktree_dir, branch_name, original_dir
# Returns: "left_in_place" or "cleaned"
cleanup_agent_worktree() {
  local worktree_dir="$1"
  local branch_name="$2"
  local original_dir="$3"
  
  if [[ ! -d "$worktree_dir" ]]; then
    echo "cleaned"
    return
  fi
  
  # Check for uncommitted changes
  if git -C "$worktree_dir" status --porcelain 2>/dev/null | grep -q .; then
    echo "left_in_place"
    return
  fi
  
  # Remove worktree
  git -C "$original_dir" worktree remove -f "$worktree_dir" >/dev/null 2>&1 || true
  
  echo "cleaned"
}

# List all ralph worktrees
list_worktrees() {
  local workspace="${1:-.}"
  git -C "$workspace" worktree list --porcelain 2>/dev/null | grep "worktree.*$WORKTREE_BASE_DIR" | sed 's/worktree //' || true
}

# Cleanup all ralph worktrees
cleanup_all_worktrees() {
  local workspace="${1:-.}"
  
  for worktree in $(list_worktrees "$workspace"); do
    git -C "$workspace" worktree remove -f "$worktree" >/dev/null 2>&1 || true
  done
  
  git -C "$workspace" worktree prune >/dev/null 2>&1 || true
}

# =============================================================================
# PARALLEL AGENT EXECUTION
# =============================================================================

# Run a single agent in its worktree
# Uses globals: RUN_ID, BASE_SHA
# Args: task_id, task_desc, display_agent_num, job_id, worktree_dir, log_file, status_file, output_file
run_agent_in_worktree() {
  local task_id="$1"
  local task_desc="$2"
  local display_agent_num="$3"
  local job_id="$4"
  local worktree_dir="$5"
  local log_file="$6"
  local status_file="$7"
  local output_file="$8"
  
  echo "running" > "$status_file"
  
  # Build the parallel agent prompt
  local report_rel=".ralph/parallel/${RUN_ID}/agent-${job_id}.md"
  local prompt="# Parallel Agent Task

You are Agent ${display_agent_num} (job: ${job_id}) working on a specific task in isolation.

## Your Task
$task_desc

## Instructions
1. Implement this specific task completely
2. Write tests if appropriate
3. Do NOT touch .ralph/progress.md in parallel mode (it causes merge conflicts)
4. Write a short report to: ${report_rel}
   - What you changed
   - Files touched
   - How to run tests
   - Any gotchas
5. Commit your changes (including the report) with a message like: ralph: [task summary]

## Important
- You are in an isolated worktree - your changes will not affect other agents
- Focus ONLY on your assigned task
- Do NOT modify RALPH_TASK.md - that will be handled by the orchestrator
- Commit frequently so your work is saved

Begin by reading any relevant files, then implement the task."
  
  # Ensure per-run report directory exists (in the worktree)
  mkdir -p "$worktree_dir/.ralph"
  mkdir -p "$worktree_dir/.ralph/parallel/${RUN_ID}"
  
  # Run cursor-agent
  echo "[$(date '+%H:%M:%S')] Agent ${display_agent_num} (job ${job_id}, task ${task_id}) starting: $task_desc" >> "$log_file"
  
  # Headless mode: auto-approve MCP servers to avoid interactive prompts.
  # Also detach stdin to prevent any accidental blocking on input.
  if cd "$worktree_dir" && cursor-agent -p --approve-mcps --force --output-format stream-json --model "$MODEL" "$prompt" >> "$log_file" 2>&1 < /dev/null; then
    echo "done" > "$status_file"
    
    # Check if any commits were made
    local commit_count
    commit_count=$(git rev-list --count HEAD ^"$BASE_SHA" 2>/dev/null || echo "0")
    
    if [[ "$commit_count" -gt 0 ]]; then
      echo "success|$commit_count" > "$output_file"
    else
      echo "no_commits|0" > "$output_file"
    fi
  else
    echo "failed" > "$status_file"
    echo "error|0" > "$output_file"
  fi
  
  echo "[$(date '+%H:%M:%S')] Agent ${display_agent_num} (job ${job_id}) finished" >> "$log_file"
}

# =============================================================================
# MERGE PHASE
# =============================================================================

# Get list of conflicted files
get_conflicted_files() {
  local workspace="${1:-.}"
  git -C "$workspace" diff --name-only --diff-filter=U 2>/dev/null || true
}

# Merge an agent branch into target
# Returns: "success", "conflict", or "error"
merge_agent_branch() {
  local branch="$1"
  local target_branch="$2"
  local workspace="$3"
  
  # Checkout target
  git -C "$workspace" checkout "$target_branch" 2>/dev/null || return 1
  
  # Attempt merge
  local git_name git_email
  git_name=$(git -C "$workspace" config user.name 2>/dev/null || true)
  git_email=$(git -C "$workspace" config user.email 2>/dev/null || true)

  local rc=0
  if [[ -n "$git_name" ]] && [[ -n "$git_email" ]]; then
    git -C "$workspace" merge --no-ff -m "Merge $branch into $target_branch" "$branch" >/dev/null 2>&1 || rc=$?
  else
    # Allow merge commits even when user.name/email aren't configured (common in CI)
    git -C "$workspace" \
      -c user.name="ralph-parallel" \
      -c user.email="ralph-parallel@localhost" \
      merge --no-ff -m "Merge $branch into $target_branch" "$branch" >/dev/null 2>&1 || rc=$?
  fi

  if [[ "$rc" -eq 0 ]]; then
    echo "success"
    return
  fi

  # Merge failed: check for conflicts vs other errors
  local conflicts
  conflicts=$(get_conflicted_files "$workspace")
  if [[ -n "$conflicts" ]]; then
    echo "conflict"
  else
    echo "error"
  fi
}

# Abort an in-progress merge
abort_merge() {
  local workspace="${1:-.}"
  git -C "$workspace" merge --abort 2>/dev/null || true
}

# Delete a local branch
delete_local_branch() {
  local branch="$1"
  local workspace="$2"
  git -C "$workspace" branch -D "$branch" 2>/dev/null || true
}

# Merge all completed branches
merge_completed_branches() {
  local workspace="$1"
  local target_branch="$2"
  shift 2
  local branches=("$@")
  
  if [[ ${#branches[@]} -eq 0 ]]; then
    return
  fi
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "📦 Merge Phase: Merging ${#branches[@]} branch(es) into $target_branch"
  echo "═══════════════════════════════════════════════════════════════════"
  
  local merged=()
  local failed=()
  
  for branch in "${branches[@]}"; do
    printf "  Merging %-50s " "$branch..."
    
    local result
    result=$(merge_agent_branch "$branch" "$target_branch" "$workspace")
    
    case "$result" in
      "success")
        echo "✅"
        merged+=("$branch")
        ;;
      "conflict")
        echo "⚠️  (conflict)"
        abort_merge "$workspace"
        failed+=("$branch")
        ;;
      *)
        echo "❌"
        failed+=("$branch")
        ;;
    esac
  done
  
  # Delete merged branches
  for branch in "${merged[@]}"; do
    delete_local_branch "$branch" "$workspace"
  done
  
  echo ""
  if [[ ${#merged[@]} -gt 0 ]]; then
    echo "✅ Successfully merged ${#merged[@]} branch(es)"
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "⚠️  Failed to merge ${#failed[@]} branch(es):"
    for branch in "${failed[@]}"; do
      echo "   - $branch"
    done
    echo "   These branches are preserved for manual review."
  fi
}

# =============================================================================
# MAIN PARALLEL RUNNER
# =============================================================================

# Run tasks in parallel with worktrees
# Args: workspace, max_parallel, base_branch, integration_branch(optional)
run_parallel_tasks() {
  local workspace="${1:-.}"
  local max_parallel="${2:-$MAX_PARALLEL}"
  local base_branch="${3:-$(git -C "$workspace" rev-parse --abbrev-ref HEAD)}"
  local integration_branch="${4:-}"
  
  # Prevent concurrent parallel runs from trampling worktrees/logs
  acquire_parallel_lock "$workspace" || return 1

  # Resolve base SHA once (use SHA everywhere to avoid ref-name brittleness)
  local base_sha
  base_sha=$(git -C "$workspace" rev-parse "$base_branch" 2>/dev/null) || {
    echo "❌ Failed to resolve base branch: $base_branch" >&2
    return 1
  }

  # Run-scoped identifiers and state dir
  RUN_ID="$(generate_unique_id)"
  RUN_DIR="$(init_parallel_run_dir "$workspace" "$RUN_ID")"

  # Export for subprocesses (subshells + agent runners)
  export MODEL
  export BASE_SHA="$base_sha"
  export BASE_BRANCH="$base_branch"
  export RUN_ID
  export RUN_DIR
  
  # Check if worktrees are usable
  if ! can_use_worktrees "$workspace"; then
    echo "❌ Cannot use worktrees (already in a worktree or no .git directory)"
    return 1
  fi
  
  local worktree_base=$(get_worktree_base "$workspace")
  local original_dir=$(cd "$workspace" && pwd)
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🚀 Parallel Execution: Up to $max_parallel agents"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "Base branch:    $base_branch"
  echo "Base SHA:       $base_sha"
  echo "Worktree base:  $worktree_base"
  echo "Run state dir:  $RUN_DIR"
  echo ""

  # Initialize run manifest (append-only for debugging)
  local manifest="$RUN_DIR/manifest.tsv"
  {
    echo -e "timestamp\tphase\tjob_id\ttask_id\tbranch\tstatus\tlog_file\tworktree_dir"
  } > "$manifest"
  
  # Get all pending tasks
  local tasks=()
  while IFS='|' read -r id status desc; do
    if [[ "$status" == "pending" ]]; then
      tasks+=("$id|$desc")
    fi
  done < <(get_all_tasks "$workspace")
  
  if [[ ${#tasks[@]} -eq 0 ]]; then
    echo "✅ No pending tasks!"
    return 0
  fi
  
  echo "📋 Found ${#tasks[@]} pending task(s)"
  echo ""
  
  # Track successful branches for merge phase (task completion only happens on successful merge)
  local successful_items=() # branch|task_id|job_id|worktree_left_in_place
  local total_succeeded=0
  local total_failed=0
  local merged_count=0
  
  # Process tasks in batches
  local batch_num=0
  local task_idx=0
  
  while [[ $task_idx -lt ${#tasks[@]} ]]; do
    batch_num=$((batch_num + 1))
    
    # Get batch of tasks
    local batch_end=$((task_idx + max_parallel))
    [[ $batch_end -gt ${#tasks[@]} ]] && batch_end=${#tasks[@]}
    local batch_size=$((batch_end - task_idx))
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 Batch $batch_num: Spawning $batch_size parallel agent(s)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Arrays for this batch
    local pids=()
    local worktree_dirs=()
    local branch_names=()
    local task_ids=()
    local task_descs=()
    local status_files=()
    local output_files=()
    local log_files=()
    local job_ids=()
    local batch_slots=()
    
    # Start agents for this batch
    for ((i = task_idx; i < batch_end; i++)); do
      local task_data="${tasks[$i]}"
      local task_id="${task_data%%|*}"
      local task_desc="${task_data#*|}"
      local global_index=$((i + 1))
      local batch_slot=$((i - task_idx + 1))
      local job_id="job${global_index}"
      
      echo "  🔄 Agent ${batch_slot}/${batch_size} (job ${job_id}, task ${task_id}): ${task_desc:0:50}..."
      
      # Create worktree
      local wt_result
      wt_result=$(create_agent_worktree "$task_id" "$task_desc" "$job_id" "$worktree_base" "$original_dir")
      local worktree_dir="${wt_result%%|*}"
      local branch_name="${wt_result#*|}"
      
      # Predictable per-run files for status/logging
      local status_file="$RUN_DIR/${job_id}.status"
      local output_file="$RUN_DIR/${job_id}.output"
      local log_file="$RUN_DIR/${job_id}.log"
      
      echo "waiting" > "$status_file"
      : > "$output_file"
      : > "$log_file"
      
      # Store for later
      worktree_dirs+=("$worktree_dir")
      branch_names+=("$branch_name")
      task_ids+=("$task_id")
      task_descs+=("$task_desc")
      status_files+=("$status_file")
      output_files+=("$output_file")
      log_files+=("$log_file")
      job_ids+=("$job_id")
      batch_slots+=("$batch_slot")
      
      # Copy RALPH_TASK.md to worktree
      cp "$workspace/RALPH_TASK.md" "$worktree_dir/" 2>/dev/null || true

      # Record in manifest
      echo -e "$(date -u '+%Y-%m-%dT%H:%M:%SZ')\tstart\t${job_id}\t${task_id}\t${branch_name}\tstarting\t${log_file}\t${worktree_dir}" >> "$manifest"
      
      # Start agent in background
      (
        run_agent_in_worktree "$task_id" "$task_desc" "$batch_slot" "$job_id" "$worktree_dir" "$log_file" "$status_file" "$output_file"
      ) &
      pids+=($!)
    done
    
    echo ""
    
    # Monitor progress with spinner
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_idx=0
    local start_time=$SECONDS
    
    while true; do
      local all_done=true
      local running=0
      local done_count=0
      local failed_count=0
      
      for ((j = 0; j < batch_size; j++)); do
        local status
        status=$(cat "${status_files[$j]}" 2>/dev/null || echo "waiting")
        
        case "$status" in
          "running") all_done=false; running=$((running + 1)) ;;
          "done") done_count=$((done_count + 1)) ;;
          "failed") failed_count=$((failed_count + 1)) ;;
          *) all_done=false ;;
        esac
      done
      
      [[ "$all_done" == "true" ]] && break
      
      local elapsed=$((SECONDS - start_time))
      printf "\r  %s Running: %d | Done: %d | Failed: %d | %02d:%02d " \
        "${spin:spin_idx:1}" "$running" "$done_count" "$failed_count" \
        $((elapsed / 60)) $((elapsed % 60))
      
      spin_idx=$(( (spin_idx + 1) % ${#spin} ))
      sleep 0.2
    done
    
    printf "\r%80s\r" ""  # Clear line
    
    # Wait for all agents to finish
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
    
    # Process results
    echo ""
    echo "Batch $batch_num Results:"
    
    for ((j = 0; j < batch_size; j++)); do
      local task_desc="${task_descs[$j]}"
      local task_id="${task_ids[$j]}"
      local job_id="${job_ids[$j]}"
      local batch_slot="${batch_slots[$j]}"
      local status
      status=$(cat "${status_files[$j]}" 2>/dev/null || echo "unknown")
      local output
      output=$(cat "${output_files[$j]}" 2>/dev/null || echo "error|0")
      local output_status="${output%%|*}"
      local branch_name="${branch_names[$j]}"
      local worktree_dir="${worktree_dirs[$j]}"
      
      local icon color
      case "$status" in
        "done")
          if [[ "$output_status" == "success" ]]; then
            icon="✅"
            total_succeeded=$((total_succeeded + 1))
          else
            icon="⚠️ "
            total_failed=$((total_failed + 1))
          fi
          ;;
        "failed")
          icon="❌"
          total_failed=$((total_failed + 1))
          ;;
        *)
          icon="❓"
          total_failed=$((total_failed + 1))
          ;;
      esac
      
      printf "  %s Agent %d (job %s): %s → %s\n" "$icon" "$batch_slot" "$job_id" "${task_desc:0:40}" "$branch_name"
      
      # Cleanup worktree
      local cleanup_result
      cleanup_result=$(cleanup_agent_worktree "$worktree_dir" "$branch_name" "$original_dir")
      if [[ "$cleanup_result" == "left_in_place" ]]; then
        echo "     ⚠️  Worktree preserved (uncommitted changes): $worktree_dir"
      fi

      # Record completion in manifest
      echo -e "$(date -u '+%Y-%m-%dT%H:%M:%SZ')\tfinish\t${job_id}\t${task_id}\t${branch_name}\t${status}/${output_status}\t${log_files[$j]}\t${worktree_dir}" >> "$manifest"

      # Track for merge phase (task completion happens on merge success)
      if [[ "$status" == "done" ]] && [[ "$output_status" == "success" ]]; then
        successful_items+=("${branch_name}|${task_id}|${job_id}|${cleanup_result}")
      fi

      # Cleanup junk branches immediately if they produced no commits / errored and worktree was removed
      if [[ "$cleanup_result" != "left_in_place" ]]; then
        if [[ "$output_status" == "no_commits" ]] || [[ "$output_status" == "error" ]]; then
          delete_local_branch "$branch_name" "$original_dir"
          echo -e "$(date -u '+%Y-%m-%dT%H:%M:%SZ')\tbranch_cleanup\t${job_id}\t${task_id}\t${branch_name}\tdeleted\t${log_files[$j]}\t${worktree_dir}" >> "$manifest"
        fi
      fi
      
      # Keep logs + manifest; remove transient status/output files
      rm -f "${status_files[$j]}" "${output_files[$j]}"
    done
    
    echo ""
    task_idx=$batch_end
  done
  
  # Merge phase
  local merge_target="$base_branch"
  if [[ -n "$integration_branch" ]]; then
    merge_target="$integration_branch"
  fi

  # If CREATE_PR is set and no integration branch provided, create a default one.
  if [[ "$CREATE_PR" == "true" ]] && [[ -z "$integration_branch" ]]; then
    merge_target="ralph/parallel-${RUN_ID}"
    integration_branch="$merge_target"
  fi

  if [[ ${#successful_items[@]} -eq 0 ]]; then
    echo ""
    echo "⚠️  No successful branches to merge."
  elif [[ "$SKIP_MERGE" == "true" ]] && [[ "$CREATE_PR" != "true" ]]; then
    echo ""
    echo "📝 Branches created (merge skipped):"
    for item in "${successful_items[@]}"; do
      local branch="${item%%|*}"
      echo "   - $branch"
    done
  else
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "📦 Merge Phase: merging ${#successful_items[@]} branch(es) into ${merge_target}"
    echo "═══════════════════════════════════════════════════════════════════"

    # Ensure merge target exists/reset (only when target differs from base branch)
    if [[ "$merge_target" != "$base_branch" ]]; then
      git -C "$original_dir" checkout -B "$merge_target" "$BASE_SHA" 2>/dev/null || {
        echo "❌ Failed to create/reset integration branch: $merge_target" >&2
        return 1
      }
    fi

    local merged_branches=()
    local failed_branches=()
    local integrated_task_ids=()

    for item in "${successful_items[@]}"; do
      local branch_name task_id job_id worktree_left
      IFS='|' read -r branch_name task_id job_id worktree_left <<< "$item"

      printf "  Merging %-55s " "$branch_name..."
      local result
      result=$(merge_agent_branch "$branch_name" "$merge_target" "$original_dir")

      case "$result" in
        "success")
          echo "✅"
          merged_count=$((merged_count + 1))
          merged_branches+=("$branch_name")
          integrated_task_ids+=("$task_id")
          echo -e "$(date -u '+%Y-%m-%dT%H:%M:%SZ')\tmerge\t${job_id}\t${task_id}\t${branch_name}\tmerged\t\t" >> "$manifest"
          # Delete merged branch if worktree was removed
          if [[ "$worktree_left" != "left_in_place" ]]; then
            delete_local_branch "$branch_name" "$original_dir"
          fi
          ;;
        "conflict")
          echo "⚠️  (conflict)"
          abort_merge "$original_dir"
          failed_branches+=("$branch_name")
          echo -e "$(date -u '+%Y-%m-%dT%H:%M:%SZ')\tmerge\t${job_id}\t${task_id}\t${branch_name}\tconflict\t\t" >> "$manifest"
          ;;
        *)
          echo "❌"
          failed_branches+=("$branch_name")
          echo -e "$(date -u '+%Y-%m-%dT%H:%M:%SZ')\tmerge\t${job_id}\t${task_id}\t${branch_name}\terror\t\t" >> "$manifest"
          ;;
      esac
    done

    # Mark tasks complete only after all merges (avoids dirty working tree breaking subsequent merges)
    for task_id in "${integrated_task_ids[@]}"; do
      mark_task_complete "$workspace" "$task_id"
    done

    # Commit task checkbox updates (only RALPH_TASK.md) so integration PR includes completion state
    if [[ ${#integrated_task_ids[@]} -gt 0 ]]; then
      if git -C "$original_dir" status --porcelain -- "RALPH_TASK.md" 2>/dev/null | grep -q .; then
        local git_name git_email
        git_name=$(git -C "$original_dir" config user.name 2>/dev/null || true)
        git_email=$(git -C "$original_dir" config user.email 2>/dev/null || true)

        git -C "$original_dir" add "RALPH_TASK.md" >/dev/null 2>&1 || true

        if [[ -n "$git_name" ]] && [[ -n "$git_email" ]]; then
          git -C "$original_dir" commit -m "ralph: mark tasks complete (${RUN_ID})" >/dev/null 2>&1 || true
        else
          git -C "$original_dir" \
            -c user.name="ralph-parallel" \
            -c user.email="ralph-parallel@localhost" \
            commit -m "ralph: mark tasks complete (${RUN_ID})" >/dev/null 2>&1 || true
        fi
      fi
    fi

    echo ""
    if [[ "$merged_count" -gt 0 ]]; then
      echo "✅ Integrated $merged_count task(s) into $merge_target"
    fi
    if [[ ${#failed_branches[@]} -gt 0 ]]; then
      echo "⚠️  Failed/conflicted branches preserved for manual review:"
      for b in "${failed_branches[@]}"; do
        echo "   - $b"
      done
    fi

    # Create a single PR for integration branch if requested
    if [[ "$CREATE_PR" == "true" ]]; then
      if [[ "$merge_target" == "$base_branch" ]]; then
        echo "⚠️  Cannot open PR: integration branch equals base branch ($base_branch)"
      else
        echo ""
        echo "📝 Creating PR: $merge_target -> $base_branch"

        if git -C "$original_dir" remote get-url origin &>/dev/null; then
          git -C "$original_dir" push -u origin "$merge_target" 2>/dev/null || git -C "$original_dir" push origin "$merge_target" || true
        else
          echo "⚠️  No remote 'origin' configured; skipping push/PR creation."
          echo "   To create a PR later, push and run:"
          echo "   git push -u origin \"$merge_target\""
          echo "   gh pr create --base \"$base_branch\" --head \"$merge_target\" --fill"
          return 0
        fi

        if command -v gh &>/dev/null; then
          (cd "$original_dir" && gh pr create --base "$base_branch" --head "$merge_target" --fill) || {
            echo "⚠️  gh pr create failed. You can create it manually with:"
            echo "   gh pr create --base \"$base_branch\" --head \"$merge_target\" --fill"
          }
        else
          echo "⚠️  gh CLI not found. Create PR manually with:"
          echo "   gh pr create --base \"$base_branch\" --head \"$merge_target\" --fill"
        fi
      fi
    fi
  fi
  
  # Summary
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "📊 Parallel Execution Complete"
  echo "═══════════════════════════════════════════════════════════════════"
  echo "  Integrated: $merged_count"
  echo "  Succeeded:  $total_succeeded"
  echo "  Failed:    $total_failed"
  echo "  Run dir:   $RUN_DIR"
  echo ""
  
  return 0
}

# =============================================================================
# CLI INTERFACE (when run directly)
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Script is being run directly
  
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/ralph-common.sh"
  source "$SCRIPT_DIR/task-parser.sh"
  
  usage() {
    echo "Usage: $0 [options] [workspace]"
    echo ""
    echo "Options:"
    echo "  -n, --max-parallel N    Max parallel agents (default: 3)"
    echo "  -b, --base-branch NAME  Base branch (default: current)"
    echo "  --no-merge              Skip auto-merge after completion"
    echo "  --pr                    Create PRs instead of auto-merge"
    echo "  -m, --model MODEL       Model to use"
    echo "  -h, --help              Show this help"
  }
  
  WORKSPACE="."
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--max-parallel)
        MAX_PARALLEL="$2"
        shift 2
        ;;
      -b|--base-branch)
        BASE_BRANCH="$2"
        shift 2
        ;;
      --no-merge)
        SKIP_MERGE=true
        shift
        ;;
      --pr)
        CREATE_PR=true
        SKIP_MERGE=true
        shift
        ;;
      -m|--model)
        MODEL="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        WORKSPACE="$1"
        shift
        ;;
    esac
  done
  
  # Run parallel tasks
  run_parallel_tasks "$WORKSPACE" "$MAX_PARALLEL" "${BASE_BRANCH:-}"
fi
