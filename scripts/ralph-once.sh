#!/bin/bash
# Ralph Wiggum: Single Iteration (DEPRECATED)
#
# This script is deprecated. Use 'ralph once' instead.
#
# Migration:
#   ./ralph-once.sh --task-file plans/api.md
#   → ralph once --task-file plans/api.md
#
# This wrapper delegates to 'ralph once' and will be removed in a future version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print deprecation warning to stderr
echo "⚠️  WARNING: ralph-once.sh is deprecated. Use 'ralph once' instead." >&2
echo "   Migration: ./ralph-once.sh [args] → ralph once [args]" >&2
echo "" >&2

# Delegate to ralph once
exec "$SCRIPT_DIR/ralph" once "$@"
