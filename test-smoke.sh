#!/bin/bash
# Smoke tests for Ralph CLI consolidation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Running smoke tests..."
echo ""

FAILED=0

# Test 1: ralph --help works
echo "Test 1: ralph --help"
if bash scripts/ralph --help 2>&1 | grep -q "Ralph Wiggum"; then
  echo "✓ PASS"
else
  echo "✗ FAIL"
  FAILED=1
fi
echo ""

# Test 2: ralph template works
echo "Test 2: ralph template"
if bash scripts/ralph template 2>&1 | grep -q "task:"; then
  echo "✓ PASS"
else
  echo "✗ FAIL"
  FAILED=1
fi
echo ""

# Test 3: bash syntax validation
echo "Test 3: bash syntax validation"
if bash -n scripts/ralph scripts/*.sh 2>&1; then
  echo "✓ PASS"
else
  echo "✗ FAIL"
  FAILED=1
fi
echo ""

if [[ $FAILED -eq 0 ]]; then
  echo "All smoke tests passed! ✓"
  exit 0
else
  echo "Some smoke tests failed. See output above."
  exit 1
fi
