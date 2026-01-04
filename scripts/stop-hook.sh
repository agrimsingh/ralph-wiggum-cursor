#!/bin/bash
# Ralph Wiggum: Stop Hook
# Manages iteration completion and fresh context decisions

set -euo pipefail

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract workspace root
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')
RALPH_DIR="$WORKSPACE_ROOT/.ralph"
STATE_FILE="$RALPH_DIR/state.md"
TASK_FILE="$WORKSPACE_ROOT/RALPH_TASK.md"
PROGRESS_FILE="$RALPH_DIR/progress.md"
FAILURES_FILE="$RALPH_DIR/failures.md"
GUARDRAILS_FILE="$RALPH_DIR/guardrails.md"

# If Ralph isn't active, allow exit
if [[ ! -f "$TASK_FILE" ]] || [[ ! -d "$RALPH_DIR" ]]; then
  exit 0
fi

# Get transcript path and read last output
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""')

LAST_OUTPUT=""
if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
  # Extract last assistant message
  if grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
    LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
    LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
      .message.content |
      map(select(.type == "text")) |
      map(.text) |
      join("\n")
    ' 2>/dev/null || echo "")
  fi
fi

# Get current state
CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" | sed 's/iteration: *//' || echo "0")

# Extract max iterations from task file
MAX_ITERATIONS=$(grep '^max_iterations:' "$TASK_FILE" | sed 's/max_iterations: *//' || echo "0")

# Check for completion signal
if echo "$LAST_OUTPUT" | grep -q "RALPH_COMPLETE"; then
  # Task completed!
  echo "✅ Ralph: Task completed after $CURRENT_ITERATION iterations!"
  
  # Update state
  sed -i "s/^status: .*/status: completed/" "$STATE_FILE"
  
  # Log completion
  cat >> "$PROGRESS_FILE" <<EOF

---

## 🎉 TASK COMPLETED

- Total iterations: $CURRENT_ITERATION
- Completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

EOF

  # Allow exit
  exit 0
fi

# Check for gutter signal
if echo "$LAST_OUTPUT" | grep -q "RALPH_GUTTER"; then
  echo "🚨 Ralph: Gutter detected! Context is polluted."
  echo ""
  echo "Recommendation: Start a fresh conversation."
  echo "Your progress is saved in:"
  echo "  - .ralph/progress.md"
  echo "  - Git history"
  echo ""
  echo "The task file (RALPH_TASK.md) and guardrails (.ralph/guardrails.md) persist."
  
  # Update state
  sed -i "s/^status: .*/status: gutter_detected/" "$STATE_FILE"
  
  # Allow exit - user should start fresh
  exit 0
fi

# Check max iterations
if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$CURRENT_ITERATION" -ge "$MAX_ITERATIONS" ]]; then
  echo "🛑 Ralph: Max iterations ($MAX_ITERATIONS) reached."
  echo ""
  echo "Progress saved in .ralph/progress.md"
  echo "To continue, increase max_iterations in RALPH_TASK.md or start fresh."
  
  # Update state
  sed -i "s/^status: .*/status: max_iterations_reached/" "$STATE_FILE"
  
  # Allow exit
  exit 0
fi

# Check for gutter risk from failures
GUTTER_RISK=$(grep 'Gutter risk:' "$FAILURES_FILE" 2>/dev/null | sed 's/.*Gutter risk: //' || echo "Low")

if [[ "$GUTTER_RISK" == "HIGH" ]]; then
  echo "⚠️ Ralph: High gutter risk detected (repeated failures)."
  echo ""
  echo "Consider starting fresh. Your progress is saved."
  echo ""
  # Don't force exit, but warn strongly
fi

# Check context health
CONTEXT_LOG="$RALPH_DIR/context-log.md"
if [[ -f "$CONTEXT_LOG" ]]; then
  CONTEXT_STATUS=$(grep 'Status:' "$CONTEXT_LOG" | head -1 || echo "")
  
  if echo "$CONTEXT_STATUS" | grep -q "Critical"; then
    echo "🔴 Ralph: Context is critically full!"
    echo ""
    echo "Strongly recommend starting a fresh conversation."
    echo "Progress is saved in files and git."
    
    # Allow exit - context is too full to continue effectively
    exit 0
  fi
fi

# Not complete - continue the loop
NEXT_ITERATION=$((CURRENT_ITERATION + 1))

# Read the task prompt
TASK_PROMPT=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$TASK_FILE")
TASK_BODY=$(awk '/^---$/{i++; next} i>=2' "$TASK_FILE")

# Check for any failure patterns to add as guardrails
if [[ -f "$FAILURES_FILE" ]]; then
  RECENT_FAILURES=$(tail -20 "$FAILURES_FILE")
  
  if echo "$RECENT_FAILURES" | grep -q "Potential Thrashing"; then
    # Extract the file that's being thrashed
    THRASH_FILE=$(echo "$RECENT_FAILURES" | grep "File:" | tail -1 | sed 's/.*File: //')
    
    if [[ -n "$THRASH_FILE" ]]; then
      # Add a guardrail
      cat >> "$GUARDRAILS_FILE" <<EOF

### Sign: Careful with $THRASH_FILE
- **Added**: Iteration $CURRENT_ITERATION
- **Reason**: Detected repeated edits without clear progress
- **Instruction**: Before editing this file again, step back and reconsider the approach

EOF
    fi
  fi
fi

# Update progress with iteration summary
cat >> "$PROGRESS_FILE" <<EOF

---

## Iteration $CURRENT_ITERATION Summary
- Ended: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Status: Continuing to iteration $NEXT_ITERATION

EOF

# Build the continuation prompt
SYSTEM_MSG="🔄 Ralph Iteration $NEXT_ITERATION

## Continue Working

Read .ralph/progress.md to see what was accomplished.
Check .ralph/guardrails.md for any new signs added.

## Reminders
- Update progress.md with your work
- Commit checkpoints
- Say RALPH_COMPLETE when ALL criteria in RALPH_TASK.md are met
- Say RALPH_GUTTER if stuck on the same issue repeatedly"

# Output JSON to block exit and continue
jq -n \
  --arg prompt "$TASK_BODY" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
