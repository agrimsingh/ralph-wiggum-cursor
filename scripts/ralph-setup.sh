#!/bin/bash
# Ralph Wiggum: Interactive Setup & Loop (DEPRECATED)
#
# This script is deprecated. Use 'ralph' instead.
#
# Migration:
#   ./ralph-setup.sh --task-file plans/api.md
#   → ralph --task-file plans/api.md
#
# This wrapper delegates to 'ralph' and will be removed in a future version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print deprecation warning to stderr
echo "⚠️  WARNING: ralph-setup.sh is deprecated. Use 'ralph' instead." >&2
echo "   Migration: ./ralph-setup.sh [args] → ralph [args]" >&2
echo "" >&2

# Delegate to ralph
exec "$SCRIPT_DIR/ralph" "$@"
