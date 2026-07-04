#!/usr/bin/env bash
#
# apply-patterns.sh - split the action's `patterns` input into groups, run
# each group's glob through filter-changed.sh, and emit the results.
#
# Environment variables:
#   PATTERNS_INPUT  - comma and/or newline separated list of glob patterns;
#                      each entry is treated as its own independent group,
#                      e.g. "src/**,*.md" is two groups.
#   CHANGED_FILES   - newline separated list of changed files to filter,
#                      normally the all_changed_files output from
#                      get-changed-files.sh.
#   GITHUB_OUTPUT   - if set, per-group and JSON outputs are appended here.
#
# Composite GitHub Actions must declare every output name statically in
# action.yml, so truly dynamic (arbitrary user text) output names aren't
# possible. This script exposes up to MAX_GROUPS individually numbered
# outputs (pattern_N / changed_N / files_N) for direct use in workflow
# expressions, plus one pattern_matches JSON array covering every group
# with no cap, for workflows that need more than MAX_GROUPS filters or
# prefer to loop over the result with fromJSON().

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${SCRIPT_DIR}/filter-changed.sh"
MAX_GROUPS=5

patterns_input="${PATTERNS_INPUT:-}"
changed_files="${CHANGED_FILES:-}"

emit_output() {
  # emit_output <key> <value> - supports multiline values via GitHub's
  # heredoc-style output format. No-op when not running inside Actions.
  local key="$1" value="$2"
  [ -z "${GITHUB_OUTPUT:-}" ] && return 0
  {
    echo "${key}<<__DIFFONLY_EOF__"
    printf '%s\n' "$value"
    echo "__DIFFONLY_EOF__"
  } >> "$GITHUB_OUTPUT"
}

json_escape() {
  # Minimal JSON string escaping: backslash, double quote, newline.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Split on commas and newlines, trim surrounding whitespace, drop blanks.
mapfile -t groups < <(
  printf '%s' "$patterns_input" \
    | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | sed '/^$/d'
)

json_entries=()
index=0

for pattern in "${groups[@]}"; do
  index=$((index + 1))
  matches="$(printf '%s\n' "$changed_files" | "$FILTER" "$pattern" || true)"

  if [ -n "$matches" ]; then
    group_changed=true
  else
    group_changed=false
  fi

  echo "pattern ${index}: ${pattern} -> changed=${group_changed}"

  if [ "$index" -le "$MAX_GROUPS" ]; then
    emit_output "pattern_${index}" "$pattern"
    emit_output "changed_${index}" "$group_changed"
    emit_output "files_${index}" "$matches"
  fi

  files_json=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    files_json+="\"$(json_escape "$f")\","
  done <<< "$matches"
  files_json="[${files_json%,}]"

  json_entries+=("{\"pattern\":\"$(json_escape "$pattern")\",\"changed\":${group_changed},\"files\":${files_json}}")
done

# Fill any unused numbered slots up to MAX_GROUPS so consuming workflows
# can safely reference pattern_N/changed_N/files_N without checking first
# how many groups were actually supplied.
i=$((index + 1))
while [ "$i" -le "$MAX_GROUPS" ]; do
  emit_output "pattern_${i}" ""
  emit_output "changed_${i}" "false"
  emit_output "files_${i}" ""
  i=$((i + 1))
done

pattern_matches_json="[$(IFS=,; echo "${json_entries[*]:-}")]"

emit_output "pattern_matches" "$pattern_matches_json"
printf '%s\n' "$pattern_matches_json"
