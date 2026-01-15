#!/bin/bash
# Smoke tests for Ralph CLI consolidation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Running smoke tests..."
echo ""

# Test 1: ralph --help works
echo "Test 1: ralph --help"
if bash scripts/ralph --help 2>&1 | grep -q "Ralph Wiggum"; then
  echo "✓ PASS"
else
  echo "✗ FAIL"
  exit 1
fi
echo ""

# Test 2: ralph template works
echo "Test 2: ralph template"
if bash scripts/ralph template 2>&1 | grep -q "task:"; then
  echo "✓ PASS"
else
  echo "✗ FAIL"
  exit 1
fi
echo ""

# Test 3: Legacy wrappers print deprecation warnings
echo "Test 3: Legacy wrappers print deprecation warnings"
# Test that deprecation warning appears in stderr (before exec)
output=$(bash scripts/ralph-setup.sh --help 2>&1 | head -5)
if echo "$output" | grep -q "deprecated"; then
  echo "✓ PASS (ralph-setup.sh)"
else
  echo "✗ FAIL (ralph-setup.sh) - output: $output"
  exit 1
fi

output=$(bash scripts/ralph-once.sh --help 2>&1 | head -5)
if echo "$output" | grep -q "deprecated"; then
  echo "✓ PASS (ralph-once.sh)"
else
  echo "✗ FAIL (ralph-once.sh) - output: $output"
  exit 1
fi

output=$(bash scripts/ralph-loop.sh --help 2>&1 | head -5)
if echo "$output" | grep -q "deprecated"; then
  echo "✓ PASS (ralph-loop.sh)"
else
  echo "✗ FAIL (ralph-loop.sh) - output: $output"
  exit 1
fi

output=$(bash scripts/init-ralph.sh --print-template 2>&1 | head -5)
if echo "$output" | grep -q "deprecated"; then
  echo "✓ PASS (init-ralph.sh --print-template)"
else
  echo "✗ FAIL (init-ralph.sh --print-template) - output: $output"
  exit 1
fi
echo ""

echo "All smoke tests passed! ✓"
