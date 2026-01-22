#!/bin/bash
# Ralph Wiggum: Stream Parser
#
# Parses Claude CLI stream-json output in real-time.
# Tracks token usage, detects failures/gutter, writes to .ralph/ logs.
#
# Usage:
#   claude -p --verbose --output-format stream-json "..." | ./stream-parser.sh /path/to/workspace
#
# Outputs to stdout:
#   - ROTATE when threshold hit (80k tokens)
#   - WARN when approaching limit (70k tokens)
#   - GUTTER when stuck pattern detected
#   - COMPLETE when agent outputs <ralph>COMPLETE</ralph>
#
# Writes to .ralph/:
#   - activity.log: all operations with context health
#   - errors.log: failures and gutter detection
#   - agent-output.log: raw JSON output from agent CLI

set -euo pipefail

WORKSPACE="${1:-.}"
RALPH_DIR="$WORKSPACE/.ralph"

# Ensure .ralph directory exists
mkdir -p "$RALPH_DIR"

# Thresholds
WARN_THRESHOLD=70000
ROTATE_THRESHOLD=80000

# Tracking state
BYTES_READ=0
BYTES_WRITTEN=0
ASSISTANT_CHARS=0
SHELL_OUTPUT_CHARS=0
PROMPT_CHARS=0
TOOL_CALLS=0
WARN_SENT=0

# Tool use/result tracking (Claude sends tool_use then tool_result separately)
LAST_TOOL_NAME=""
LAST_TOOL_INPUT=""
LAST_TOOL_PATH=""

# Estimate initial prompt size (Ralph prompt is ~2KB + file references)
PROMPT_CHARS=3000

# Gutter detection - use temp files instead of associative arrays (macOS bash 3.x compat)
FAILURES_FILE=$(mktemp)
WRITES_FILE=$(mktemp)
trap "rm -f $FAILURES_FILE $WRITES_FILE" EXIT

# Get context health emoji
get_health_emoji() {
  local tokens=$1
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  
  if [[ $pct -lt 60 ]]; then
    echo "🟢"
  elif [[ $pct -lt 80 ]]; then
    echo "🟡"
  else
    echo "🔴"
  fi
}

calc_tokens() {
  local total_bytes=$((PROMPT_CHARS + BYTES_READ + BYTES_WRITTEN + ASSISTANT_CHARS + SHELL_OUTPUT_CHARS))
  echo $((total_bytes / 4))
}

# Log to activity.log
log_activity() {
  local message="$1"
  local timestamp=$(date '+%H:%M:%S')
  local tokens=$(calc_tokens)
  local emoji=$(get_health_emoji $tokens)
  
  echo "[$timestamp] $emoji $message" >> "$RALPH_DIR/activity.log"
}

# Log to errors.log
log_error() {
  local message="$1"
  local timestamp=$(date '+%H:%M:%S')
  
  echo "[$timestamp] $message" >> "$RALPH_DIR/errors.log"
}

# Check and log token status
log_token_status() {
  local tokens=$(calc_tokens)
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  local emoji=$(get_health_emoji $tokens)
  local timestamp=$(date '+%H:%M:%S')
  
  local status_msg="TOKENS: $tokens / $ROTATE_THRESHOLD ($pct%)"
  
  if [[ $pct -ge 90 ]]; then
    status_msg="$status_msg - rotation imminent"
  elif [[ $pct -ge 72 ]]; then
    status_msg="$status_msg - approaching limit"
  fi
  
  local breakdown="[read:$((BYTES_READ/1024))KB write:$((BYTES_WRITTEN/1024))KB assist:$((ASSISTANT_CHARS/1024))KB shell:$((SHELL_OUTPUT_CHARS/1024))KB]"
  echo "[$timestamp] $emoji $status_msg $breakdown" >> "$RALPH_DIR/activity.log"
}

# Check for gutter conditions
check_gutter() {
  local tokens=$(calc_tokens)
  
  # Check rotation threshold
  if [[ $tokens -ge $ROTATE_THRESHOLD ]]; then
    log_activity "ROTATE: Token threshold reached ($tokens >= $ROTATE_THRESHOLD)"
    echo "ROTATE" 2>/dev/null || true
    return
  fi
  
  # Check warning threshold (only emit once per session)
  if [[ $tokens -ge $WARN_THRESHOLD ]] && [[ $WARN_SENT -eq 0 ]]; then
    log_activity "WARN: Approaching token limit ($tokens >= $WARN_THRESHOLD)"
    WARN_SENT=1
    echo "WARN" 2>/dev/null || true
  fi
}

# Track shell command failure
track_shell_failure() {
  local cmd="$1"
  local exit_code="$2"
  
  if [[ $exit_code -ne 0 ]]; then
    # Count failures for this command (grep -c exits 1 if no match, so use || true)
    local count
    count=$(grep -c "^${cmd}$" "$FAILURES_FILE" 2>/dev/null) || count=0
    count=$((count + 1))
    echo "$cmd" >> "$FAILURES_FILE"
    
    log_error "SHELL FAIL: $cmd → exit $exit_code (attempt $count)"
    
    if [[ $count -ge 3 ]]; then
      log_error "⚠️ GUTTER: same command failed ${count}x"
      echo "GUTTER" 2>/dev/null || true
    fi
  fi
}

# Track file writes for thrashing detection
track_file_write() {
  local path="$1"
  local now=$(date +%s)
  
  # Log write with timestamp
  echo "$now:$path" >> "$WRITES_FILE"
  
  # Count writes to this file in last 10 minutes
  local cutoff=$((now - 600))
  local count=$(awk -F: -v cutoff="$cutoff" -v path="$path" '
    $1 >= cutoff && $2 == path { count++ }
    END { print count+0 }
  ' "$WRITES_FILE")
  
  # Check for thrashing (5+ writes in 10 minutes)
  if [[ $count -ge 5 ]]; then
    log_error "⚠️ THRASHING: $path written ${count}x in 10 min"
    echo "GUTTER" 2>/dev/null || true
  fi
}

# Process a single JSON line from stream
process_line() {
  local line="$1"

  # Skip empty lines
  [[ -z "$line" ]] && return

  # Parse JSON type
  local type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || return
  local subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null) || true

  case "$type" in
    # Handle session init (Claude: "system" with subtype "init")
    "system")
      if [[ "$subtype" == "init" ]]; then
        local model=$(echo "$line" | jq -r '.model // "unknown"' 2>/dev/null) || model="unknown"
        log_activity "SESSION START: model=$model"
      fi
      ;;

    # Handle assistant messages (Claude: "assistant" with .message.content)
    "assistant")
      # Track assistant message characters - try both formats
      local text=$(echo "$line" | jq -r '.message.content[0].text // empty' 2>/dev/null) || text=""
      if [[ -z "$text" ]]; then
        # Also try .content[].text for some message formats
        text=$(echo "$line" | jq -r '.content[0].text // empty' 2>/dev/null) || text=""
      fi

      if [[ -n "$text" ]]; then
        local chars=${#text}
        ASSISTANT_CHARS=$((ASSISTANT_CHARS + chars))

        # Check for completion sigil
        if [[ "$text" == *"<ralph>COMPLETE</ralph>"* ]]; then
          log_activity "✅ Agent signaled COMPLETE"
          echo "COMPLETE" 2>/dev/null || true
        fi

        # Check for gutter sigil
        if [[ "$text" == *"<ralph>GUTTER</ralph>"* ]]; then
          log_activity "🚨 Agent signaled GUTTER (stuck)"
          echo "GUTTER" 2>/dev/null || true
        fi
      fi
      ;;

    # Handle tool invocation start (Claude CLI format)
    "tool_use")
      TOOL_CALLS=$((TOOL_CALLS + 1))

      # Extract tool name and input for matching with tool_result
      LAST_TOOL_NAME=$(echo "$line" | jq -r '.name // empty' 2>/dev/null) || LAST_TOOL_NAME=""

      # Extract path from input based on tool type
      case "$LAST_TOOL_NAME" in
        "Read")
          LAST_TOOL_PATH=$(echo "$line" | jq -r '.input.file_path // empty' 2>/dev/null) || LAST_TOOL_PATH=""
          ;;
        "Write")
          LAST_TOOL_PATH=$(echo "$line" | jq -r '.input.file_path // empty' 2>/dev/null) || LAST_TOOL_PATH=""
          ;;
        "Edit")
          LAST_TOOL_PATH=$(echo "$line" | jq -r '.input.file_path // empty' 2>/dev/null) || LAST_TOOL_PATH=""
          ;;
        "Bash")
          LAST_TOOL_INPUT=$(echo "$line" | jq -r '.input.command // empty' 2>/dev/null) || LAST_TOOL_INPUT=""
          ;;
        "Glob"|"Grep")
          LAST_TOOL_PATH=$(echo "$line" | jq -r '.input.pattern // empty' 2>/dev/null) || LAST_TOOL_PATH=""
          ;;
      esac
      ;;

    # Handle tool execution result (Claude CLI format)
    "tool_result")
      local output=$(echo "$line" | jq -r '.output // empty' 2>/dev/null) || output=""
      local content=$(echo "$line" | jq -r '.content // empty' 2>/dev/null) || content=""
      local result_text="${output}${content}"
      local bytes=${#result_text}

      case "$LAST_TOOL_NAME" in
        "Read")
          BYTES_READ=$((BYTES_READ + bytes))
          local kb=$(echo "scale=1; $bytes / 1024" | bc 2>/dev/null || echo "$((bytes / 1024))")
          log_activity "READ $LAST_TOOL_PATH (~${kb}KB)"
          ;;
        "Write")
          BYTES_WRITTEN=$((BYTES_WRITTEN + bytes))
          local kb=$(echo "scale=1; $bytes / 1024" | bc 2>/dev/null || echo "$((bytes / 1024))")
          log_activity "WRITE $LAST_TOOL_PATH (~${kb}KB)"
          track_file_write "$LAST_TOOL_PATH"
          ;;
        "Edit")
          # Edit is typically smaller changes
          BYTES_WRITTEN=$((BYTES_WRITTEN + bytes))
          log_activity "EDIT $LAST_TOOL_PATH"
          track_file_write "$LAST_TOOL_PATH"
          ;;
        "Bash")
          SHELL_OUTPUT_CHARS=$((SHELL_OUTPUT_CHARS + bytes))
          # Try to extract exit code from output if present
          local exit_code=0
          if [[ "$result_text" == *"exit code"* ]] || [[ "$result_text" == *"Error"* ]] || [[ "$result_text" == *"error"* ]]; then
            # Check for common error patterns
            if [[ "$result_text" == *"exit code 1"* ]] || [[ "$result_text" == *"FAILED"* ]]; then
              exit_code=1
            fi
          fi

          if [[ $exit_code -eq 0 ]]; then
            if [[ $bytes -gt 1024 ]]; then
              log_activity "BASH $LAST_TOOL_INPUT → ok (${bytes} chars)"
            else
              log_activity "BASH $LAST_TOOL_INPUT → ok"
            fi
          else
            log_activity "BASH $LAST_TOOL_INPUT → failed"
            track_shell_failure "$LAST_TOOL_INPUT" "$exit_code"
          fi
          ;;
        "Glob"|"Grep")
          BYTES_READ=$((BYTES_READ + bytes))
          log_activity "SEARCH $LAST_TOOL_PATH (~${bytes} chars)"
          ;;
        *)
          # Unknown tool, just track as read
          BYTES_READ=$((BYTES_READ + bytes))
          log_activity "TOOL $LAST_TOOL_NAME (~${bytes} chars)"
          ;;
      esac

      # Reset tracking
      LAST_TOOL_NAME=""
      LAST_TOOL_INPUT=""
      LAST_TOOL_PATH=""

      # Check thresholds after each tool result
      check_gutter
      ;;

    # Handle session end
    "result")
      local duration=$(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null) || duration=0
      local tokens=$(calc_tokens)
      log_activity "SESSION END: ${duration}ms, ~$tokens tokens used"
      ;;
  esac
}

# Main loop: read JSON lines from stdin
main() {
  local agent_output_log="$RALPH_DIR/agent-output.log"

  # Initialize activity log for this session
  echo "" >> "$RALPH_DIR/activity.log"
  echo "═══════════════════════════════════════════════════════════════" >> "$RALPH_DIR/activity.log"
  echo "Ralph Session Started: $(date)" >> "$RALPH_DIR/activity.log"
  echo "═══════════════════════════════════════════════════════════════" >> "$RALPH_DIR/activity.log"

  # Initialize agent output log for this session
  echo "" >> "$agent_output_log"
  echo "═══════════════════════════════════════════════════════════════" >> "$agent_output_log"
  echo "# Session Started: $(date)" >> "$agent_output_log"
  echo "═══════════════════════════════════════════════════════════════" >> "$agent_output_log"

  # Track last token log time
  local last_token_log=$(date +%s)

  while IFS= read -r line; do
    # Append raw line to agent output log
    echo "$line" >> "$agent_output_log"

    # Process the line for activity tracking
    process_line "$line"

    # Log token status every 30 seconds
    local now=$(date +%s)
    if [[ $((now - last_token_log)) -ge 30 ]]; then
      log_token_status
      last_token_log=$now
    fi
  done

  # Final token status
  log_token_status

  # Mark session end in agent output log
  echo "" >> "$agent_output_log"
  echo "# Session Ended: $(date)" >> "$agent_output_log"
}

main
