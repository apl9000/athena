#!/usr/bin/env bash
# Runs swift test with code coverage and enforces a minimum line coverage
# percentage across Sources/. Used both locally (`make coverage`) and by CI.
set -euo pipefail

THRESHOLD="${COVERAGE_THRESHOLD:-90.0}"

cd "$(dirname "$0")/.."

echo "==> Running tests with coverage instrumentation..."
swift test --enable-code-coverage

BIN_PATH="$(swift build --show-bin-path)"
PROFDATA="${BIN_PATH}/codecov/default.profdata"
if [ ! -f "$PROFDATA" ]; then
  echo "ERROR: coverage profile not found at $PROFDATA" >&2
  exit 1
fi

XCTEST_BUNDLE="$(find "$BIN_PATH" -maxdepth 1 -name '*PackageTests.xctest' | head -n 1)"
if [ -z "$XCTEST_BUNDLE" ]; then
  echo "ERROR: no *PackageTests.xctest bundle found in $BIN_PATH" >&2
  exit 1
fi
TEST_BIN="${XCTEST_BUNDLE}/Contents/MacOS/$(basename "$XCTEST_BUNDLE" .xctest)"
if [ ! -x "$TEST_BIN" ]; then
  echo "ERROR: test binary not executable: $TEST_BIN" >&2
  exit 1
fi

SOURCE_FILES=$(find Sources -name '*.swift' -type f | sort)

echo "==> Generating LCOV report..."
xcrun llvm-cov export \
  -format=lcov \
  -instr-profile "$PROFDATA" \
  "$TEST_BIN" \
  $SOURCE_FILES > coverage.lcov

echo "==> Per-file coverage:"
xcrun llvm-cov report \
  -instr-profile "$PROFDATA" \
  "$TEST_BIN" \
  $SOURCE_FILES \
  -use-color=false

TOTAL_LINE=$(xcrun llvm-cov report \
  -instr-profile "$PROFDATA" \
  "$TEST_BIN" \
  $SOURCE_FILES \
  -use-color=false | awk '/^TOTAL/ {print}')

if [ -z "$TOTAL_LINE" ]; then
  echo "ERROR: could not find TOTAL line in coverage report" >&2
  exit 1
fi

# llvm-cov report TOTAL columns: TOTAL Regions Missed Cover Functions Missed Cover Lines Missed Cover Branches Missed Cover
LINE_COVERAGE=$(echo "$TOTAL_LINE" | awk '{print $10}' | tr -d '%')

echo ""
echo "==> Total line coverage: ${LINE_COVERAGE}% (threshold: ${THRESHOLD}%)"

if awk -v c="$LINE_COVERAGE" -v t="$THRESHOLD" 'BEGIN { exit !(c+0 < t+0) }'; then
  echo "FAIL: line coverage ${LINE_COVERAGE}% is below threshold ${THRESHOLD}%" >&2
  exit 1
fi

echo "PASS: line coverage ${LINE_COVERAGE}% meets threshold ${THRESHOLD}%"
