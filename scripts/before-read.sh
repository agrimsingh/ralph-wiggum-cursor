#!/bin/bash
# Ralph Wiggum: Before Read File Hook
# Tracks context allocations to prevent redlining

set -euo pipefail

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract file info
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.file_path // ""')
CONTENT=$(echo "$HOOK_INPUT" | jq -r '.content // ""')
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')

RALPH_DIR="$WORKSPACE_ROOT/.ralph"
CONTEXT_LOG="$RALPH_DIR/context-log.md"

# If Ralph isn't active, pass through
if [[ ! -d "$RALPH_DIR" ]]; then
  echo '{"continue": true, "permission": "allow"}'
  exit 0
fi

# Estimate token count (rough: ~4 chars per token)
CONTENT_LENGTH=${#CONTENT}
ESTIMATED_TOKENS=$((CONTENT_LENGTH / 4))

# Log the file read
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Append to context log (in the table)
if [[ -f "$CONTEXT_LOG" ]]; then
  # Find the table and append
  # This is a simplified approach - in production you'd want more robust parsing
  
  # Read current allocated tokens
  CURRENT_ALLOCATED=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -oP '\d+' || echo "0")
  NEW_ALLOCATED=$((CURRENT_ALLOCATED + ESTIMATED_TOKENS))
  
  # Update the allocated count
  sed -i "s/Allocated: [0-9]* tokens/Allocated: $NEW_ALLOCATED tokens/" "$CONTEXT_LOG"
  
  # Determine status
  THRESHOLD=80000
  WARN_THRESHOLD=$((THRESHOLD * 80 / 100))
  CRITICAL_THRESHOLD=$((THRESHOLD * 95 / 100))
  
  if [[ "$NEW_ALLOCATED" -gt "$CRITICAL_THRESHOLD" ]]; then
    STATUS="🔴 Critical - Start fresh!"
    sed -i "s/Status: .*/Status: $STATUS/" "$CONTEXT_LOG"
  elif [[ "$NEW_ALLOCATED" -gt "$WARN_THRESHOLD" ]]; then
    STATUS="🟡 Warning - Approaching limit"
    sed -i "s/Status: .*/Status: $STATUS/" "$CONTEXT_LOG"
  fi
  
  # Log this file (append before the Estimated Context Usage section)
  # Using a temp file approach for safety
  TEMP_FILE=$(mktemp)
  awk -v file="$FILE_PATH" -v tokens="$ESTIMATED_TOKENS" -v ts="$TIMESTAMP" '
    /^## Estimated Context Usage/ {
      print "| " file " | " tokens " | " ts " |"
      print ""
    }
    { print }
  ' "$CONTEXT_LOG" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$CONTEXT_LOG"
fi

# Check if we should warn about context
THRESHOLD=80000
CRITICAL_THRESHOLD=$((THRESHOLD * 95 / 100))

if [[ -f "$CONTEXT_LOG" ]]; then
  CURRENT_ALLOCATED=$(grep 'Allocated:' "$CONTEXT_LOG" | grep -oP '\d+' || echo "0")
  
  if [[ "$CURRENT_ALLOCATED" -gt "$CRITICAL_THRESHOLD" ]]; then
    # Context is critically full - warn but allow
    jq -n \
      --arg file "$FILE_PATH" \
      '{
        "continue": true,
        "permission": "allow",
        "userMessage": "⚠️ Ralph: Context is critically full. Consider starting a fresh conversation.",
        "agentMessage": "CONTEXT CRITICAL: You are approaching context limits. Wrap up current work, commit, and suggest starting fresh."
      }'
    exit 0
  fi
fi

# Normal case - allow the read
echo '{"continue": true, "permission": "allow"}'
exit 0
