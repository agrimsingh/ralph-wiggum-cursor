#!/bin/bash
# Ralph Wiggum: Before Prompt Hook
# Injects guardrails and context awareness into prompts

set -euo pipefail

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract workspace root
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')
RALPH_DIR="$WORKSPACE_ROOT/.ralph"
TASK_FILE="$WORKSPACE_ROOT/RALPH_TASK.md"

# Check if Ralph is active
if [[ ! -f "$TASK_FILE" ]]; then
  # No Ralph task - pass through
  exit 0
fi

# Initialize Ralph state directory if needed
if [[ ! -d "$RALPH_DIR" ]]; then
  mkdir -p "$RALPH_DIR"
  
  # Initialize state file
  cat > "$RALPH_DIR/state.md" <<EOF
---
iteration: 0
status: initializing
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---

# Ralph State

Waiting for first iteration to begin.
EOF

  # Initialize guardrails file
  cat > "$RALPH_DIR/guardrails.md" <<EOF
# Ralph Guardrails (Signs)

These are lessons learned from previous iterations. Follow these to avoid known pitfalls.

## Core Signs

### Sign: Read Before Writing
- **Always** read existing files before modifying them
- Check git history for context on why things are the way they are

### Sign: Test After Changes
- Run tests after every significant change
- Don't assume code works - verify it

### Sign: Commit Checkpoints
- Commit working states before attempting risky changes
- Use descriptive commit messages

---

## Learned Signs

(Signs added from observed failures will appear below)

EOF

  # Initialize context log
  cat > "$RALPH_DIR/context-log.md" <<EOF
# Context Allocation Log

Tracking what's been loaded into context to prevent redlining.

## Current Session

| File | Size (est tokens) | Timestamp |
|------|-------------------|-----------|

## Estimated Context Usage

- Allocated: 0 tokens
- Threshold: 80000 tokens (warn at 80%)
- Status: 🟢 Healthy

EOF

  # Initialize failures log
  cat > "$RALPH_DIR/failures.md" <<EOF
# Failure Log

Tracking failure patterns to detect "gutter" situations.

## Recent Failures

(Failures will be logged here)

## Pattern Detection

- Repeated failures: 0
- Gutter risk: Low

EOF

  # Initialize progress log
  cat > "$RALPH_DIR/progress.md" <<EOF
# Progress Log

## Summary

- Iterations completed: 0
- Tasks completed: 0
- Current status: Not started

## Iteration History

(Progress will be logged here)

EOF
fi

# Read current state
STATE_FILE="$RALPH_DIR/state.md"
GUARDRAILS_FILE="$RALPH_DIR/guardrails.md"
CONTEXT_LOG="$RALPH_DIR/context-log.md"

# Extract current iteration
CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" | sed 's/iteration: *//' || echo "0")
NEXT_ITERATION=$((CURRENT_ITERATION + 1))

# Update iteration count
sed -i "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE"
sed -i "s/^status: .*/status: active/" "$STATE_FILE"

# Check context health
ESTIMATED_TOKENS=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -oP '\d+' || echo "0")
THRESHOLD=80000
WARN_THRESHOLD=$((THRESHOLD * 80 / 100))

CONTEXT_WARNING=""
if [[ "$ESTIMATED_TOKENS" -gt "$WARN_THRESHOLD" ]]; then
  CONTEXT_WARNING="⚠️ CONTEXT WARNING: Approaching limit ($ESTIMATED_TOKENS tokens). Consider starting fresh."
fi

# Read guardrails
GUARDRAILS=""
if [[ -f "$GUARDRAILS_FILE" ]]; then
  # Extract learned signs section
  GUARDRAILS=$(sed -n '/## Learned Signs/,$ p' "$GUARDRAILS_FILE" | tail -n +3)
fi

# Build agent message with Ralph context
AGENT_MSG="🔄 **Ralph Iteration $NEXT_ITERATION**

$CONTEXT_WARNING

## Your Task
Read RALPH_TASK.md for the full task description and completion criteria.

## Key Files
- \`.ralph/progress.md\` - What's been accomplished
- \`.ralph/guardrails.md\` - Signs to follow (lessons learned)
- \`.ralph/state.md\` - Current iteration state

## Ralph Protocol
1. Read progress.md to see what's done
2. Check guardrails.md for signs to follow
3. Work on the NEXT incomplete item from RALPH_TASK.md
4. Update progress.md with what you accomplished
5. Commit your changes with a descriptive message
6. If ALL completion criteria are met, say: \"RALPH_COMPLETE: All criteria satisfied\"
7. If stuck on same issue 3+ times, say: \"RALPH_GUTTER: Need fresh context\"

## Current Guardrails
$GUARDRAILS

Remember: Progress is tracked in FILES, not in context. Always update progress.md."

# Output JSON response
# Note: beforeSubmitPrompt currently may not support modification in Cursor
# This is here for future compatibility and logging purposes
jq -n \
  --arg msg "$AGENT_MSG" \
  '{
    "continue": true,
    "agentMessage": $msg
  }'

exit 0
