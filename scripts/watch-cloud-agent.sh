#!/bin/bash
# Ralph Wiggum: Cloud Agent Watcher
# - Polls agent status until completion
# - Chains agents if task isn't done
# - Uses follow-up for nudges
# - Merges completed branches

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

POLL_INTERVAL=30        # seconds between status checks
MAX_CHAIN_DEPTH=10      # max agents to chain before giving up
FOLLOWUP_ATTEMPTS=3     # nudges before spawning new agent

CONFIG_FILE="${WORKSPACE_ROOT:-.}/.cursor/ralph-config.json"
GLOBAL_CONFIG="$HOME/.cursor/ralph-config.json"

# =============================================================================
# HELPERS
# =============================================================================

get_api_key() {
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then echo "$CURSOR_API_KEY" && return 0; fi
  if [[ -f "$CONFIG_FILE" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$KEY" ]]; then echo "$KEY" && return 0; fi
  fi
  if [[ -f "$GLOBAL_CONFIG" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$GLOBAL_CONFIG" 2>/dev/null || echo "")
    if [[ -n "$KEY" ]]; then echo "$KEY" && return 0; fi
  fi
  return 1
}

get_agent_status() {
  local agent_id="$1"
  local api_key="$2"
  
  curl -s "https://api.cursor.com/v0/agents/$agent_id" -u "$api_key:" 2>/dev/null
}

get_agent_conversation() {
  local agent_id="$1"
  local api_key="$2"
  
  curl -s "https://api.cursor.com/v0/agents/$agent_id/conversation" -u "$api_key:" 2>/dev/null
}

send_followup() {
  local agent_id="$1"
  local api_key="$2"
  local message="$3"
  
  curl -s -X POST "https://api.cursor.com/v0/agents/$agent_id/followup" \
    -u "$api_key:" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg msg "$message" '{"prompt": {"text": $msg}}')" 2>/dev/null
}

spawn_continuation_agent() {
  local workspace="$1"
  local prev_agent_id="$2"
  local prev_branch="$3"
  local iteration="$4"
  
  "$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace"
}

check_task_complete() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$task_file" ]]; then
    echo "NO_TASK_FILE"
    return
  fi
  
  # Count unchecked criteria (supports "- [ ]" and "1. [ ]" formats)
  local unchecked=$(grep -c '\[ \]' "$task_file" 2>/dev/null || echo "0")
  unchecked=$(echo "$unchecked" | tr -cd '0-9')
  [[ -z "$unchecked" ]] && unchecked=0
  
  if [[ "$unchecked" -eq 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$unchecked"
  fi
}

# =============================================================================
# MAIN WATCHER LOOP
# =============================================================================

watch_agent() {
  local agent_id="$1"
  local workspace="$2"
  local chain_depth="${3:-1}"
  local followup_count=0
  
  API_KEY=$(get_api_key) || {
    echo "❌ No API key configured" >&2
    exit 1
  }
  
  echo "═══════════════════════════════════════════════════════════════════"
  echo "👁️  Ralph Watcher: Monitoring Cloud Agent"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "Agent ID:    $agent_id"
  echo "Workspace:   $workspace"
  echo "Chain depth: $chain_depth / $MAX_CHAIN_DEPTH"
  echo "Monitor:     https://cursor.com/agents?id=$agent_id"
  echo ""
  echo "Polling every ${POLL_INTERVAL}s... (Ctrl+C to stop)"
  echo ""
  
  while true; do
    # Get agent status
    RESPONSE=$(get_agent_status "$agent_id" "$API_KEY")
    STATUS=$(echo "$RESPONSE" | jq -r '.status // "UNKNOWN"')
    SUMMARY=$(echo "$RESPONSE" | jq -r '.summary // ""')
    BRANCH=$(echo "$RESPONSE" | jq -r '.target.branchName // ""')
    
    TIMESTAMP=$(date '+%H:%M:%S')
    
    case "$STATUS" in
      "RUNNING")
        echo "[$TIMESTAMP] 🔄 Agent running..."
        followup_count=0
        ;;
        
      "FINISHED")
        echo "[$TIMESTAMP] ✅ Agent finished!"
        echo ""
        echo "Summary: $SUMMARY"
        echo "Branch:  $BRANCH"
        echo ""
        
        # Pull the branch and check if task is complete
        cd "$workspace"
        git fetch origin "$BRANCH" 2>/dev/null || true
        git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH" 2>/dev/null || true
        git pull origin "$BRANCH" 2>/dev/null || true
        
        TASK_STATUS=$(check_task_complete "$workspace")
        
        if [[ "$TASK_STATUS" == "COMPLETE" ]]; then
          echo "🎉 RALPH COMPLETE! All criteria satisfied."
          echo ""
          echo "Branch '$BRANCH' contains the completed work."
          echo "Merge it when ready: git checkout main && git merge $BRANCH"
          exit 0
          
        elif [[ "$TASK_STATUS" == "NO_TASK_FILE" ]]; then
          echo "⚠️  No RALPH_TASK.md found. Cannot verify completion."
          exit 0
          
        else
          REMAINING=$(echo "$TASK_STATUS" | cut -d: -f2)
          echo "📋 Task incomplete: $REMAINING criteria remaining"
          echo ""
          
          if [[ "$chain_depth" -ge "$MAX_CHAIN_DEPTH" ]]; then
            echo "⚠️  Max chain depth ($MAX_CHAIN_DEPTH) reached. Stopping."
            echo "   Continue manually: cd $workspace && git checkout $BRANCH"
            exit 1
          fi
          
          echo "🔗 Chaining: Spawning new agent to continue..."
          echo ""
          
          # Spawn continuation agent
          NEW_AGENT_OUTPUT=$("$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace" 2>&1)
          NEW_AGENT_ID=$(echo "$NEW_AGENT_OUTPUT" | grep "Agent ID:" | awk '{print $NF}')
          
          if [[ -n "$NEW_AGENT_ID" ]]; then
            echo "$NEW_AGENT_OUTPUT"
            echo ""
            # Recursive watch
            watch_agent "$NEW_AGENT_ID" "$workspace" $((chain_depth + 1))
            exit $?
          else
            echo "❌ Failed to spawn continuation agent"
            echo "$NEW_AGENT_OUTPUT"
            exit 1
          fi
        fi
        ;;
        
      "STOPPED")
        echo "[$TIMESTAMP] ⏸️  Agent stopped"
        
        if [[ "$followup_count" -lt "$FOLLOWUP_ATTEMPTS" ]]; then
          followup_count=$((followup_count + 1))
          echo "   Sending follow-up nudge ($followup_count/$FOLLOWUP_ATTEMPTS)..."
          
          NUDGE="Continue working on the Ralph task. Check RALPH_TASK.md for remaining criteria marked [ ]. Run tests after changes. Say RALPH_COMPLETE when all criteria are satisfied."
          
          send_followup "$agent_id" "$API_KEY" "$NUDGE"
          echo "   ✓ Follow-up sent"
        else
          echo "   Max follow-ups reached. Spawning new agent..."
          
          if [[ "$chain_depth" -ge "$MAX_CHAIN_DEPTH" ]]; then
            echo "⚠️  Max chain depth reached. Stopping."
            exit 1
          fi
          
          NEW_AGENT_OUTPUT=$("$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace" 2>&1)
          NEW_AGENT_ID=$(echo "$NEW_AGENT_OUTPUT" | grep "Agent ID:" | awk '{print $NF}')
          
          if [[ -n "$NEW_AGENT_ID" ]]; then
            watch_agent "$NEW_AGENT_ID" "$workspace" $((chain_depth + 1))
            exit $?
          else
            echo "❌ Failed to spawn new agent"
            exit 1
          fi
        fi
        ;;
        
      "EXPIRED")
        echo "[$TIMESTAMP] ⏰ Agent expired"
        echo "   Spawning new agent..."
        
        if [[ "$chain_depth" -ge "$MAX_CHAIN_DEPTH" ]]; then
          echo "⚠️  Max chain depth reached. Stopping."
          exit 1
        fi
        
        NEW_AGENT_OUTPUT=$("$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace" 2>&1)
        NEW_AGENT_ID=$(echo "$NEW_AGENT_OUTPUT" | grep "Agent ID:" | awk '{print $NF}')
        
        if [[ -n "$NEW_AGENT_ID" ]]; then
          watch_agent "$NEW_AGENT_ID" "$workspace" $((chain_depth + 1))
          exit $?
        else
          echo "❌ Failed to spawn new agent"
          exit 1
        fi
        ;;
        
      "ERROR"|"FAILED")
        echo "[$TIMESTAMP] ❌ Agent failed: $STATUS"
        echo "   Summary: $SUMMARY"
        
        # Get conversation to see what went wrong
        CONVERSATION=$(get_agent_conversation "$agent_id" "$API_KEY")
        LAST_MESSAGE=$(echo "$CONVERSATION" | jq -r '.messages[-1].text // "No messages"' | head -c 500)
        echo "   Last message: $LAST_MESSAGE..."
        echo ""
        
        if [[ "$chain_depth" -ge "$MAX_CHAIN_DEPTH" ]]; then
          echo "⚠️  Max chain depth reached. Stopping."
          exit 1
        fi
        
        echo "   Spawning new agent to retry..."
        NEW_AGENT_OUTPUT=$("$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace" 2>&1)
        NEW_AGENT_ID=$(echo "$NEW_AGENT_OUTPUT" | grep "Agent ID:" | awk '{print $NF}')
        
        if [[ -n "$NEW_AGENT_ID" ]]; then
          watch_agent "$NEW_AGENT_ID" "$workspace" $((chain_depth + 1))
          exit $?
        else
          echo "❌ Failed to spawn new agent"
          exit 1
        fi
        ;;
        
      "CREATING")
        echo "[$TIMESTAMP] 🔧 Agent creating..."
        ;;
        
      *)
        echo "[$TIMESTAMP] ❓ Unknown status: $STATUS"
        ;;
    esac
    
    sleep "$POLL_INTERVAL"
  done
}

# =============================================================================
# ENTRY POINT
# =============================================================================

usage() {
  echo "Usage: $0 <agent-id> [workspace]"
  echo ""
  echo "Watch a Cloud Agent and chain new agents until task is complete."
  echo ""
  echo "Arguments:"
  echo "  agent-id   The Cloud Agent ID (e.g., bc-abc123)"
  echo "  workspace  Path to workspace (default: current directory)"
  echo ""
  echo "Examples:"
  echo "  $0 bc-c1b07cd8-e35a-4366-8d74-d53d16c18bba"
  echo "  $0 bc-abc123 /path/to/project"
  echo ""
  echo "The watcher will:"
  echo "  1. Poll agent status every ${POLL_INTERVAL}s"
  echo "  2. Send follow-ups if agent stops prematurely"
  echo "  3. Spawn new agents when current one finishes but task isn't done"
  echo "  4. Chain up to $MAX_CHAIN_DEPTH agents before giving up"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

AGENT_ID="$1"
WORKSPACE="${2:-.}"

if [[ "$WORKSPACE" == "." ]]; then
  WORKSPACE="$(pwd)"
fi

watch_agent "$AGENT_ID" "$WORKSPACE" 1
