#!/usr/bin/env bash
#
# run-tests.sh - hand-rolled unit tests for scripts/filter-changed.sh.
#
# Plain bash assertions on purpose: no bats, no test framework to install
# in CI, nothing beyond the bash that's already required to run the action
# itself. Run it directly: ./test/run-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${SCRIPT_DIR}/../scripts/filter-changed.sh"

pass_count=0
fail_count=0

# assert_match <description> <file-list> <expected-matches> <pattern> [<pattern> ...]
#   file-list and expected-matches are newline-separated strings.
assert_match() {
  local description="$1" file_list="$2" expected="$3"
  shift 3
  local actual
  actual="$(printf '%s\n' "$file_list" | "$FILTER" "$@")"
  actual_status=$?

  if [ "$actual" = "$expected" ]; then
    echo "ok - ${description}"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL - ${description}"
    echo "  patterns: $*"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual:   $(printf '%q' "$actual")"
    fail_count=$((fail_count + 1))
  fi
}

# assert_exit <description> <expected-exit-code> <file-list> <pattern> [<pattern> ...]
assert_exit() {
  local description="$1" expected_status="$2" file_list="$3"
  shift 3
  local actual_status
  printf '%s\n' "$file_list" | "$FILTER" "$@" >/dev/null 2>&1
  actual_status=$?

  if [ "$actual_status" -eq "$expected_status" ]; then
    echo "ok - ${description}"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL - ${description}"
    echo "  expected exit code: ${expected_status}"
    echo "  actual exit code:   ${actual_status}"
    fail_count=$((fail_count + 1))
  fi
}

files="README.md
src/index.js
src/lib/util.js
src/lib/deep/nested/helper.js
docs/guide.md
package.json
notes.txt"

# --- exact match -------------------------------------------------------
assert_match "exact match hits only the named file" \
  "$files" \
  "README.md" \
  "README.md"

# --- extension match (*.ext) -------------------------------------------
assert_match "*.md matches only top-level markdown files" \
  "$files" \
  "README.md" \
  "*.md"

assert_match "*.js does not match nested files (single star stops at /)" \
  "$files" \
  "" \
  "*.js"

# --- ** recursive glob ---------------------------------------------------
assert_match "src/** matches every file under src at any depth" \
  "$files" \
  "src/index.js
src/lib/util.js
src/lib/deep/nested/helper.js" \
  "src/**"

assert_match "**.js matches .js files at any depth including root" \
  "root.js
src/index.js
src/lib/deep/nested/helper.js
notes.txt" \
  "root.js
src/index.js
src/lib/deep/nested/helper.js" \
  "**.js"

# --- non-matching file correctly excluded -------------------------------
assert_match "notes.txt is excluded by an unrelated pattern" \
  "$files" \
  "" \
  "*.yaml"

assert_exit "no match yields exit code 1" 1 "$files" "*.yaml"
assert_exit "at least one match yields exit code 0" 0 "$files" "*.md"

# --- multiple patterns (OR'd together) ----------------------------------
assert_match "multiple patterns are combined with OR" \
  "$files" \
  "README.md
docs/guide.md
package.json" \
  "*.md" "docs/**" "package.json"

# --- ? single-character wildcard ----------------------------------------
assert_match "? matches exactly one character" \
  "a.js
ab.js
a/b.js" \
  "a.js" \
  "?.js"

echo
echo "${pass_count} passed, ${fail_count} failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
