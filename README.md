# diffonly-action

A "changed files" GitHub Action with a total dependency count of zero. It's a
composite action written entirely in `bash`, calling nothing but `git` and
`jq` (both already present on every GitHub-hosted runner). There is no
`node_modules`, no bundled JavaScript, no package lock file, and no
third-party supply chain to compromise.

## Why this exists

In March 2025, `tj-actions/changed-files` — a widely used third-party GitHub
Action for computing changed files in a workflow — was compromised. Attackers
modified the action so that it dumped CI/CD secrets straight into workflow
run logs, disguised inside what looked like ordinary output. Because the
action was so popular, this reportedly affected well over 20,000
repositories before it was caught. GitHub responded by temporarily pulling
the action from the Marketplace while the incident was investigated.

The uncomfortable part of that story isn't that one action had a bug — it's
that almost nobody using it had actually read its code. It pulled in a
JavaScript dependency chain, ran a compiled/bundled artifact, and got
updated automatically by tag. Most consumers had no realistic way to audit
what was actually executing in their CI pipeline on every run.

`diffonly-action` is a direct, practical response to that failure mode. The
entire implementation — the composite action definition plus three small
shell scripts — is short enough to read start to finish in a few minutes.
There's no build step, no `npm install`, no transpiled bundle standing
between what you read in this repository and what actually runs in your
workflow. If you don't trust it, you can read every line of it yourself,
right now, in this repo.

It intentionally does less than the action it's meant to replace. It does
one job — figuring out which files changed and filtering them against
simple glob patterns — and does it in a way that's fully auditable.

## What it does

Given the two commits that bracket a `push` or `pull_request` event (or an
explicit `base-ref` you provide), it:

1. Runs `git diff --name-only <base>...<head>` to get the list of changed
   files.
2. Optionally filters that list against one or more glob-style patterns.
3. Exposes the results as step outputs your workflow can branch on.

## Usage

### Basic usage

```yaml
name: CI

on:
  pull_request:

jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # required - diffonly-action needs full history

      - id: diff
        uses: Async360/diffonly-action@v1

      - name: List what changed
        run: |
          echo "any changed: ${{ steps.diff.outputs.any_changed }}"
          echo "${{ steps.diff.outputs.all_changed_files }}"
```

### Conditional jobs and a matrix, driven by pattern groups

Each entry in `patterns` (comma- and/or newline-separated) is its own
independent group with its own `changed_N` / `files_N` output pair, so
downstream jobs can each key off exactly the part of the tree they care
about:

```yaml
name: CI

on:
  pull_request:

jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      backend_changed: ${{ steps.diff.outputs.changed_1 }}
      frontend_changed: ${{ steps.diff.outputs.changed_2 }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - id: diff
        uses: Async360/diffonly-action@v1
        with:
          patterns: |
            backend/**
            frontend/**

  test-backend:
    needs: changes
    if: needs.changes.outputs.backend_changed == 'true'
    runs-on: ubuntu-latest
    strategy:
      matrix:
        python-version: ['3.10', '3.11', '3.12']
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}
      - run: pytest

  test-frontend:
    needs: changes
    if: needs.changes.outputs.frontend_changed == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm test
```

Need more than one glob to count as a single group ("changed if backend
code *or* any Python file changed")? Combine two `if:` checks with `||` in
the consuming job, or filter `all_changed_files` yourself in a small script
step - `all_changed_files` is always the complete, unfiltered list.

## Inputs

| Input      | Required | Default | Description |
|------------|----------|---------|-------------|
| `base-ref` | no       | `''`    | Git ref/SHA to diff against. Left empty, it's auto-detected: the PR base SHA for `pull_request`/`pull_request_target` events, or the previous pushed commit for `push` events (falling back to the empty tree for a repo's first-ever commit). |
| `patterns` | no       | `''`    | Comma and/or newline separated list of glob patterns. Each entry is its own group. Leave empty to skip filtering. |

## Outputs

| Output                     | Description |
|----------------------------|-------------|
| `all_changed_files`        | Newline-separated list of every changed file (unfiltered). |
| `any_changed`               | `"true"`/`"false"` - whether anything changed at all. |
| `pattern_matches`           | JSON array of `{pattern, changed, files}`, one entry per group in `patterns`, covering **every** group with no cap. Empty array if `patterns` wasn't set. |
| `pattern_1` … `pattern_5`  | The glob text for group *N*. |
| `changed_1` … `changed_5`  | `"true"`/`"false"` for group *N*. |
| `files_1` … `files_5`      | Newline-separated matched files for group *N*. |

Composite GitHub Actions have to declare every output name statically in
`action.yml`, so truly dynamic output names (derived from arbitrary
user-supplied glob text) aren't technically possible. `pattern_1`…`pattern_5`
/ `changed_1`…`changed_5` / `files_1`…`files_5` cover the first five groups
directly as step outputs; `pattern_matches` covers all of them, unlimited,
as JSON for use with `fromJSON()` in more advanced workflows.

## Glob syntax supported

Implemented in [`scripts/filter-changed.sh`](scripts/filter-changed.sh),
matched against the file's full repo-relative path:

| Token | Meaning |
|-------|---------|
| `*`   | Zero or more characters, but never a `/` (stays within one path segment) |
| `**`  | Zero or more characters, **including** `/` - matches across directories, wherever it appears in the pattern |
| `?`   | Exactly one character, but never a `/` |
| anything else | Matched literally |

Examples:

- `README.md` — matches only that exact file.
- `*.md` — matches `README.md`, but **not** `docs/guide.md` (single `*`
  doesn't cross a `/`).
- `**.md` — matches both `README.md` and `docs/guide.md` (the `**` here
  isn't confined to a whole path segment, so it happily expands to nothing
  or to `docs/`).
- `src/**` — matches every file anywhere under `src/`.

**Not supported, on purpose:** character classes (`[abc]`), brace expansion
(`{a,b}`), negation (`!pattern`), extglob. The goal is a glob engine small
enough that every rule above is the *entire* spec - not a subset of some
larger, harder-to-audit implementation.

## Security posture

- **Zero third-party dependencies.** No `node_modules`, no lockfile, no
  bundled/minified code, nothing pulled from npm or any other package
  registry at build or run time.
- **Two runtime dependencies, both already on the runner:** `git` and `jq`.
  Both ship on GitHub-hosted `ubuntu-latest` / `macos-latest` /
  `windows-latest` images.
- **Composite, not JavaScript.** `action.yml` runs plain `bash` scripts
  straight out of this repository - there's no build/bundle step that could
  diverge from what's checked in, and nothing resembling the
  compiled-artifact-vs-source-mismatch pattern that let the tj-actions
  compromise hide in plain sight.
- **Small enough to read.** `action.yml` plus the three scripts under
  `scripts/` add up to a few hundred lines total. Pin `@v1` (or a commit
  SHA, if you want to be stricter still) and read the diff before you ever
  bump it.

## Development

```bash
git clone https://github.com/Async360/diffonly-action.git
cd diffonly-action
./test/run-tests.sh
```

`test/run-tests.sh` is a hand-rolled bash assertion script - no test
framework to install, in CI or locally. The end-to-end behavior (the actual
`git diff` logic across push/pull_request event contexts) is exercised by
[`.github/workflows/test.yml`](.github/workflows/test.yml), which runs the
action against itself using a throwaway commit on every push and pull
request to this repo.

## License

MIT - see [LICENSE](LICENSE).
