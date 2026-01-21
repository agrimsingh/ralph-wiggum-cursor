#!/bin/bash
# Ralph Wiggum: Stream Parser
#
# Parses cursor-agent stream-json output in real-time.
# Tracks token usage, detects failures/gutter, writes to .ralph/ logs.
#
# Usage:
#   cursor-agent -p --force --output-format stream-json "..." | ./stream-parser.sh /path/to/workspace [model]
#
# Arguments:
#   $1 - workspace: path to the workspace root
#   $2 - model: (optional) model name for context window sizing (default: custom)
#
# Model-aware thresholds (80% of published context windows):
#   - sonnet-4.5-thinking: 800k (1M context in MAX mode)
#   - gemini-3-pro:        800k (1M context in MAX mode)
#   - gpt-5.2-high:        217k (272k context in MAX mode)
#   - opus-4.5-thinking:   160k (200k context)
#   - custom/unknown:      80k  (100k conservative default)
#
# Outputs to stdout:
#   - ROTATE when threshold hit
#   - WARN when approaching limit
#   - GUTTER when stuck pattern detected
#   - COMPLETE when agent outputs <ralph>COMPLETE</ralph>
#
# Writes to .ralph/:
#   - activity.log: all operations with context health
#   - errors.log: failures and gutter detection

set -euo pipefail

WORKSPACE="${1:-.}"
MODEL="${2:-custom}"
RALPH_DIR="$WORKSPACE/.ralph"

# Ensure .ralph directory exists
mkdir -p "$RALPH_DIR"

# =============================================================================
# MODEL-AWARE TOKEN THRESHOLDS
# =============================================================================
# Thresholds are set to ~80% of published context window limits.
# This leaves headroom for system prompts and safety margin.
#
# Published context windows (MAX mode where applicable):
#   - sonnet-4.5-thinking: 1M    → 80% = 800,000
#   - gemini-3-pro:        1M    → 80% = 800,000
#   - gpt-5.2-high:        272k  → 80% = 217,600
#   - opus-4.5-thinking:   200k  → 80% = 160,000
#   - composer-1:          200k  → 80% = 160,000
#   - custom/unknown:      100k  → 80% = 80,000
# =============================================================================

get_model_thresholds() {
  local model="$1"
  local warn rotate
  
  case "$model" in
    *sonnet*4.5*thinking*|*sonnet*thinking*4.5*)
      # Sonnet 4.5 thinking has 1M context (MAX mode)
      rotate=800000
      warn=700000
      ;;
    *gemini*3*pro*|*gemini-3-pro*)
      # Gemini 3 Pro has 1M context (MAX mode)
      rotate=800000
      warn=700000
      ;;
    *gpt-5*|*gpt5*)
      # GPT-5.x: 272k context (MAX mode)
      rotate=217600
      warn=190000
      ;;
    *opus*4.5*thinking*|*opus*thinking*4.5*|*opus-4.5*)
      # Opus 4.5: 200k context
      rotate=160000
      warn=140000
      ;;
    *composer*)
      # Composer: 200k context
      rotate=160000
      warn=140000
      ;;
    *sonnet*4*|*claude*sonnet*)
      # Other Sonnet models: 200k context
      rotate=160000
      warn=140000
      ;;
    *opus*|*claude*opus*)
      # Other Opus models: 200k context
      rotate=160000
      warn=140000
      ;;
    *)
      # Custom/unknown models: conservative 100k → 80k threshold
      rotate=80000
      warn=70000
      ;;
  esac
  
  echo "$warn $rotate"
}

# Get thresholds for selected model
read WARN_THRESHOLD ROTATE_THRESHOLD <<< $(get_model_thresholds "$MODEL")

# Tracking state
BYTES_READ=0
BYTES_WRITTEN=0
ASSISTANT_CHARS=0
SHELL_OUTPUT_CHARS=0
PROMPT_CHARS=0
TOOL_CALLS=0
WARN_SENT=0

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
    "system")
      if [[ "$subtype" == "init" ]]; then
        local model=$(echo "$line" | jq -r '.model // "unknown"' 2>/dev/null) || model="unknown"
        log_activity "SESSION START: model=$model"
      fi
      ;;
      
    "assistant")
      # Track assistant message characters
      local text=$(echo "$line" | jq -r '.message.content[0].text // empty' 2>/dev/null) || text=""
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
      
    "tool_call")
      if [[ "$subtype" == "started" ]]; then
        TOOL_CALLS=$((TOOL_CALLS + 1))
        
      elif [[ "$subtype" == "completed" ]]; then
        # Handle read tool completion
        if echo "$line" | jq -e '.tool_call.readToolCall.result.success' > /dev/null 2>&1; then
          local path=$(echo "$line" | jq -r '.tool_call.readToolCall.args.path // "unknown"' 2>/dev/null) || path="unknown"
          local lines=$(echo "$line" | jq -r '.tool_call.readToolCall.result.success.totalLines // 0' 2>/dev/null) || lines=0
          
          local content_size=$(echo "$line" | jq -r '.tool_call.readToolCall.result.success.contentSize // 0' 2>/dev/null) || content_size=0
          local bytes
          if [[ $content_size -gt 0 ]]; then
            bytes=$content_size
          else
            bytes=$((lines * 100))  # ~100 chars/line for code
          fi
          BYTES_READ=$((BYTES_READ + bytes))
          
          local kb=$(echo "scale=1; $bytes / 1024" | bc 2>/dev/null || echo "$((bytes / 1024))")
          log_activity "READ $path ($lines lines, ~${kb}KB)"
          
        # Handle write tool completion
        elif echo "$line" | jq -e '.tool_call.writeToolCall.result.success' > /dev/null 2>&1; then
          local path=$(echo "$line" | jq -r '.tool_call.writeToolCall.args.path // "unknown"' 2>/dev/null) || path="unknown"
          local lines=$(echo "$line" | jq -r '.tool_call.writeToolCall.result.success.linesCreated // 0' 2>/dev/null) || lines=0
          local bytes=$(echo "$line" | jq -r '.tool_call.writeToolCall.result.success.fileSize // 0' 2>/dev/null) || bytes=0
          BYTES_WRITTEN=$((BYTES_WRITTEN + bytes))
          
          local kb=$(echo "scale=1; $bytes / 1024" | bc 2>/dev/null || echo "$((bytes / 1024))")
          log_activity "WRITE $path ($lines lines, ${kb}KB)"
          
          # Track for thrashing detection
          track_file_write "$path"
          
        # Handle shell tool completion
        elif echo "$line" | jq -e '.tool_call.shellToolCall.result' > /dev/null 2>&1; then
          local cmd=$(echo "$line" | jq -r '.tool_call.shellToolCall.args.command // "unknown"' 2>/dev/null) || cmd="unknown"
          local exit_code=$(echo "$line" | jq -r '.tool_call.shellToolCall.result.exitCode // 0' 2>/dev/null) || exit_code=0
          
          local stdout=$(echo "$line" | jq -r '.tool_call.shellToolCall.result.stdout // ""' 2>/dev/null) || stdout=""
          local stderr=$(echo "$line" | jq -r '.tool_call.shellToolCall.result.stderr // ""' 2>/dev/null) || stderr=""
          local output_chars=$((${#stdout} + ${#stderr}))
          SHELL_OUTPUT_CHARS=$((SHELL_OUTPUT_CHARS + output_chars))
          
          if [[ $exit_code -eq 0 ]]; then
            if [[ $output_chars -gt 1024 ]]; then
              log_activity "SHELL $cmd → exit 0 (${output_chars} chars output)"
            else
              log_activity "SHELL $cmd → exit 0"
            fi
          else
            log_activity "SHELL $cmd → exit $exit_code"
            track_shell_failure "$cmd" "$exit_code"
          fi
        fi
        
        # Check thresholds after each tool call
        check_gutter
      fi
      ;;
      
    "result")
      local duration=$(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null) || duration=0
      local tokens=$(calc_tokens)
      log_activity "SESSION END: ${duration}ms, ~$tokens tokens used"
      ;;
  esac
}

# Main loop: read JSON lines from stdin
main() {
  # Initialize activity log for this session
  echo "" >> "$RALPH_DIR/activity.log"
  echo "═══════════════════════════════════════════════════════════════" >> "$RALPH_DIR/activity.log"
  echo "Ralph Session Started: $(date)" >> "$RALPH_DIR/activity.log"
  echo "Model: $MODEL | Token limit: $ROTATE_THRESHOLD (warn: $WARN_THRESHOLD)" >> "$RALPH_DIR/activity.log"
  echo "═══════════════════════════════════════════════════════════════" >> "$RALPH_DIR/activity.log"
  
  # Track last token log time
  local last_token_log=$(date +%s)
  
  while IFS= read -r line; do
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
}

main
