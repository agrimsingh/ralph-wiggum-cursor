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

# Test 3: Legacy wrappers print deprecation warnings
echo "Test 3: Legacy wrappers print deprecation warnings"

# Test ralph-setup.sh
echo "  Testing ralph-setup.sh..."
output=$(bash scripts/ralph-setup.sh --help 2>&1 || true)
if echo "$output" | head -5 | grep -q "deprecated"; then
  echo "  ✓ PASS (ralph-setup.sh)"
else
  echo "  ✗ FAIL (ralph-setup.sh)"
  echo "    Output: $(echo "$output" | head -5)"
  FAILED=1
fi

# Test ralph-once.sh
echo "  Testing ralph-once.sh..."
output=$(bash scripts/ralph-once.sh --help 2>&1 || true)
if echo "$output" | head -5 | grep -q "deprecated"; then
  echo "  ✓ PASS (ralph-once.sh)"
else
  echo "  ✗ FAIL (ralph-once.sh)"
  echo "    Output: $(echo "$output" | head -5)"
  FAILED=1
fi

# Test ralph-loop.sh
echo "  Testing ralph-loop.sh..."
output=$(bash scripts/ralph-loop.sh --help 2>&1 || true)
if echo "$output" | head -5 | grep -q "deprecated"; then
  echo "  ✓ PASS (ralph-loop.sh)"
else
  echo "  ✗ FAIL (ralph-loop.sh)"
  echo "    Output: $(echo "$output" | head -5)"
  FAILED=1
fi

# Test init-ralph.sh --print-template
echo "  Testing init-ralph.sh --print-template..."
output=$(bash scripts/init-ralph.sh --print-template 2>&1 || true)
if echo "$output" | head -5 | grep -q "deprecated"; then
  echo "  ✓ PASS (init-ralph.sh --print-template)"
else
  echo "  ✗ FAIL (init-ralph.sh --print-template)"
  echo "    Output: $(echo "$output" | head -5)"
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
