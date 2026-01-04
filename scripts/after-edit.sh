#!/bin/bash
# Ralph Wiggum: After File Edit Hook
# Tracks progress and detects failure patterns

set -euo pipefail

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract file info
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.file_path // ""')
OLD_CONTENT=$(echo "$HOOK_INPUT" | jq -r '.old_content // ""')
NEW_CONTENT=$(echo "$HOOK_INPUT" | jq -r '.new_content // ""')
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')

RALPH_DIR="$WORKSPACE_ROOT/.ralph"
PROGRESS_FILE="$RALPH_DIR/progress.md"
STATE_FILE="$RALPH_DIR/state.md"

# If Ralph isn't active, pass through
if [[ ! -d "$RALPH_DIR" ]]; then
  exit 0
fi

# Get current iteration
CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" | sed 's/iteration: *//' || echo "0")

# Calculate change size
OLD_LENGTH=${#OLD_CONTENT}
NEW_LENGTH=${#NEW_CONTENT}
CHANGE_SIZE=$((NEW_LENGTH - OLD_LENGTH))

if [[ $CHANGE_SIZE -lt 0 ]]; then
  CHANGE_SIZE=$((-CHANGE_SIZE))
  CHANGE_TYPE="removed"
else
  CHANGE_TYPE="added"
fi

# Log the edit to progress
TIMESTAMP=$(date -u +%H:%M:%S)

# Append to progress file
cat >> "$PROGRESS_FILE" <<EOF

### Edit: $FILE_PATH
- Time: $TIMESTAMP
- Change: $CHANGE_SIZE chars $CHANGE_TYPE
EOF

# Check for potential failure patterns
# Look for reverts (new content similar to much older content)
# This is a simplified heuristic

# Check if this file has been edited multiple times in this iteration
EDIT_COUNT=$(grep -c "Edit: $FILE_PATH" "$PROGRESS_FILE" 2>/dev/null || echo "0")

if [[ "$EDIT_COUNT" -gt 5 ]]; then
  # Possible thrashing on this file
  FAILURES_FILE="$RALPH_DIR/failures.md"
  
  cat >> "$FAILURES_FILE" <<EOF

## Potential Thrashing Detected
- File: $FILE_PATH
- Edits in session: $EDIT_COUNT
- Iteration: $CURRENT_ITERATION
- Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Consider: Is this file being repeatedly modified without progress?

EOF

  # Update pattern detection
  REPEATED_FAILURES=$(grep -c "Potential Thrashing" "$FAILURES_FILE" 2>/dev/null || echo "0")
  sed -i "s/Repeated failures: [0-9]*/Repeated failures: $REPEATED_FAILURES/" "$FAILURES_FILE"
  
  if [[ "$REPEATED_FAILURES" -gt 2 ]]; then
    sed -i "s/Gutter risk: .*/Gutter risk: HIGH/" "$FAILURES_FILE"
  fi
fi

exit 0
