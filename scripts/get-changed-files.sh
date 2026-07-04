#!/usr/bin/env bash
#
# get-changed-files.sh - print the files changed in the current run.
#
# Figures out the correct base/head commits for the current GitHub Actions
# event (pull_request / pull_request_target vs push vs anything else) and
# runs `git diff --name-only <base>...<head>` between them.
#
# Configuration is read from environment variables so this script works
# whether it's invoked by action.yml or by hand:
#   GITHUB_EVENT_NAME   - e.g. "push", "pull_request"
#   GITHUB_EVENT_PATH   - path to the event JSON payload
#   BASE_REF_INPUT      - optional explicit override for the base ref/sha,
#                         wired up to the action's `base-ref` input
#   GITHUB_OUTPUT       - if set, results are also appended here in the
#                         format the Actions runner expects
#
# The head side of the diff is always the currently checked-out commit
# (HEAD). That's deliberate: HEAD is whatever the runner actually has on
# disk, so it can never go stale, whereas the head SHA recorded in the
# event payload can - e.g. if a workflow makes its own commit after
# checkout, GITHUB_SHA and event.after/event.pull_request.head.sha still
# point at the commit that triggered the run, not the new one. Only the
# *base* side genuinely differs by event type and isn't otherwise
# knowable from the local checkout, so that's the only thing this script
# reads out of the event JSON.
#
# Always prints the changed file list to stdout, one path per line (empty
# output if nothing changed).

set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "get-changed-files.sh: required command '$1' not found" >&2
    exit 2
  }
}

require_cmd git
require_cmd jq

event_name="${GITHUB_EVENT_NAME:-}"
event_path="${GITHUB_EVENT_PATH:-}"
base_override="${BASE_REF_INPUT:-}"

empty_tree() {
  git hash-object -t tree /dev/null
}

has_commit() {
  [ -n "$1" ] && git rev-parse --quiet --verify "${1}^{commit}" >/dev/null 2>&1
}

base_sha=""
head_sha="HEAD"

if [ -n "$event_path" ] && [ -f "$event_path" ]; then
  case "$event_name" in
    pull_request|pull_request_target)
      base_sha="$(jq -r '.pull_request.base.sha // empty' "$event_path")"
      ;;
    push)
      base_sha="$(jq -r '.before // empty' "$event_path")"
      ;;
  esac
fi

if [ -n "$base_override" ]; then
  base_sha="$base_override"
fi

# A brand new branch push (or a force-push) reports an all-zero "before"
# SHA that doesn't exist in the repo. A shallow checkout (the
# actions/checkout default) can also leave a perfectly valid base SHA
# unreachable locally. Either way, fall back to the parent of head, or -
# for a repository's very first commit, which has no parent - the empty
# tree, so the diff still produces a sensible answer instead of erroring.
if ! has_commit "$base_sha"; then
  if [ -n "$base_sha" ]; then
    echo "get-changed-files.sh: base commit '${base_sha}' not found locally (shallow checkout? use actions/checkout with fetch-depth: 0), falling back to the previous commit" >&2
  fi
  if has_commit "${head_sha}^"; then
    base_sha="${head_sha}^"
  else
    base_sha="$(empty_tree)"
  fi
fi

changed_files="$(git diff --no-renames --name-only "${base_sha}...${head_sha}" 2>/dev/null || true)"

# Three-dot diff needs a real merge base between two commits. If base_sha
# ended up being the empty tree, or otherwise isn't something `git
# merge-base` can use, fall back to a plain two-dot diff, which `git diff`
# happily accepts for tree objects too.
if [ -z "$changed_files" ]; then
  changed_files="$(git diff --no-renames --name-only "${base_sha}" "${head_sha}" 2>/dev/null || true)"
fi

changed_files="$(printf '%s\n' "$changed_files" | sed '/^$/d')"

printf '%s\n' "$changed_files"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "all_changed_files<<__DIFFONLY_EOF__"
    printf '%s\n' "$changed_files"
    echo "__DIFFONLY_EOF__"
    if [ -n "$changed_files" ]; then
      echo "any_changed=true"
    else
      echo "any_changed=false"
    fi
  } >> "$GITHUB_OUTPUT"
fi
