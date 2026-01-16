#!/bin/bash
# Ralph Wiggum: Initialize Ralph (DEPRECATED)
#
# This script is deprecated. Use 'ralph init' or 'ralph template' instead.
#
# Migration:
#   ./init-ralph.sh                    → ralph init
#   ./init-ralph.sh --print-template    → ralph template
#
# This wrapper delegates to 'ralph' and will be removed in a future version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for --print-template flag
if [[ "${1:-}" == "--print-template" ]]; then
  # Print deprecation warning to stderr
  echo "⚠️  WARNING: init-ralph.sh --print-template is deprecated. Use 'ralph template' instead." >&2
  echo "   Migration: ./init-ralph.sh --print-template → ralph template" >&2
  echo "" >&2
  # Delegate to ralph template
  exec "$SCRIPT_DIR/ralph" template
else
  # Print deprecation warning to stderr
  echo "⚠️  WARNING: init-ralph.sh is deprecated. Use 'ralph init' instead." >&2
  echo "   Migration: ./init-ralph.sh → ralph init" >&2
  echo "" >&2
  # Delegate to ralph init
  exec "$SCRIPT_DIR/ralph" init "$@"
fi
