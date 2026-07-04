#!/usr/bin/env bash
#
# filter-changed.sh - match a list of file paths against one or more
# glob-style patterns.
#
# Usage:
#   filter-changed.sh <glob-pattern> [<glob-pattern> ...] < file-list.txt
#
# Reads newline-separated file paths from stdin and prints (to stdout,
# newline-separated) the subset that matches at least one of the given
# patterns. Exits 0 if at least one file matched, 1 if none matched, 2 on a
# usage error.
#
# This script has no side effects and touches nothing outside stdin/stdout,
# so it can be exercised directly by test/run-tests.sh without any GitHub
# Actions runtime around it.
#
# Supported glob syntax (see README.md for the full writeup):
#   *   matches zero or more characters, but never a `/` (one path segment)
#   **  matches zero or more characters, INCLUDING `/` (any depth, anywhere
#       it appears in the pattern - not just as a whole path segment)
#   ?   matches exactly one character, but never a `/`
#   anything else is matched literally
#
# Deliberately NOT supported: character classes ([abc]), brace expansion
# ({a,b}), negation (!pattern), extglob. Keeping the feature set small means
# the whole translation below fits on one screen and can be verified by eye.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: filter-changed.sh <glob-pattern> [<glob-pattern> ...] < file-list" >&2
  exit 2
fi

# Translate a single glob pattern into a POSIX extended regular expression,
# anchored at both ends. Written as an explicit character-by-character walk
# rather than a chain of sed substitutions, so the translation rules stay
# unambiguous.
glob_to_regex() {
  local glob="$1"
  local regex=""
  local len=${#glob}
  local i=0
  local c next

  while [ "$i" -lt "$len" ]; do
    c="${glob:$i:1}"
    case "$c" in
      '*')
        next="${glob:$((i + 1)):1}"
        if [ "$next" = '*' ]; then
          regex+='.*'
          i=$((i + 2))
          continue
        fi
        regex+='[^/]*'
        ;;
      '?')
        regex+='[^/]'
        ;;
      '.'|'['|']'|'('|')'|'+'|'^'|'$'|'{'|'}'|'|'|'\')
        regex+="\\${c}"
        ;;
      *)
        regex+="$c"
        ;;
    esac
    i=$((i + 1))
  done

  printf '^%s$' "$regex"
}

regexes=()
for pattern in "$@"; do
  regexes+=("$(glob_to_regex "$pattern")")
done

found=false
while IFS= read -r file || [ -n "$file" ]; do
  [ -z "$file" ] && continue
  for regex in "${regexes[@]}"; do
    if [[ "$file" =~ $regex ]]; then
      printf '%s\n' "$file"
      found=true
      break
    fi
  done
done

if [ "$found" = true ]; then
  exit 0
else
  exit 1
fi
