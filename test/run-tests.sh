#!/usr/bin/env bash
# Run infovore ERT tests in batch mode.
# Usage: ./test/run-tests.sh [TEST-FILE...]
# If no arguments, runs all test files in test/.

set -euo pipefail

EMACS="${EMACS:-emacs}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Elpaca builds directory (where dependencies are installed).
ELPACA_BUILDS="$HOME/.emacs.d/elpaca/builds"

# Build load-path arguments: project root + each dependency.
LOAD_ARGS=(-L "$PROJECT_DIR" -L "$PROJECT_DIR/test")
for dep in emacsql gptel compat; do
  dep_dir="${ELPACA_BUILDS}/${dep}"
  if [ -d "$dep_dir" ]; then
    LOAD_ARGS+=(-L "$dep_dir")
  fi
done

# Determine which test files to run.
if [ $# -gt 0 ]; then
  TEST_FILES=("$@")
else
  TEST_FILES=("$PROJECT_DIR"/test/*-test.el)
fi

TOTAL=0
PASSED=0
FAILED=0

for test_file in "${TEST_FILES[@]}"; do
  echo "=== Running $(basename "$test_file") ==="
  if "$EMACS" -Q --batch "${LOAD_ARGS[@]}" \
       -l ert \
       -l "$PROJECT_DIR/test/test-stubs.el" \
       -l "$test_file" \
       -f ert-run-tests-batch-and-exit 2>&1; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  TOTAL=$((TOTAL + 1))
  echo ""
done

echo "=== Summary: ${PASSED}/${TOTAL} test files passed, ${FAILED} failed ==="
[ "$FAILED" -eq 0 ]
