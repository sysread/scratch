# Coding Conventions

This document describes the coding conventions used in scratch.
The rules are strict: consistency is what makes a large shell codebase legible.

## Prime Directive

Separation of concerns.
A function that changes behavior drastically based on a parameter is TWO FUNCTIONS.
Keep special cases off the API.
Make the right thing the easiest thing.

## Language and Output Discipline

Bash is the default.
Reach for other tools when they fit the problem better (see `libexec/embed.exs` for Elixir).
The shell orchestrates; everything else is a tool called from the shell.

`stdout` is program data.
`stderr` is messages, logs, errors, help text.
No exceptions.
This is what makes `scratch foo | jq` work reliably and `scratch foo 2>/dev/null` cleanly suppress chatter.

`usage()` functions pipe through `tui:format >&2`.
Help text is stderr.

All user-facing logging goes through `tui:log` / `tui:debug` / `tui:info` / `tui:warn` / `tui:error`.
These are structured via `gum log`.
`tui:format` renders markdown via `gum format` on a TTY and falls back to `cat` when piped.

## Error Handling

`die` uses `return 1`, not `exit 1`.
Top-level scripts rely on `set -e` to propagate.
This keeps `die` usable from sourced libraries and functions without killing the whole process unexpectedly.

Precondition guards are single-line: `<predicate> || die "<message>"`.

`tui:die` is for user-facing structured errors - it routes through gum before dying.

Errors must be *useful*: explain what went wrong, how to fix it, and include enough context to act on.

## Naming

Kebab-case ("belt-case") for function names and file names.
Never snake_case.

Library functions use `namespace:verb-noun` with colons as separators.
Examples: `tui:choose-one`, `project:detect`, `cmd:required-arg`.

Private/internal library functions use a leading underscore.
Examples: `_cmd:resolve-flag`, `_cmd:format_help`.

Bin-local functions (not exported) use bare kebab-case without a namespace.
Examples: `do-list`, `resolve-name`, `fetch-issue`.

Globals and script-scope variables are ALL_CAPS.
Lowercase signals "local to this function."

Library-internal globals are prefixed with underscore + lib name.
Examples: `_TUI_SCRIPTDIR`, `_INCLUDED_BASE`, `_CMD_ARG_ORDER`.

## Variables

One `local` declaration per line.
Never combined on a single line.
Easier to read, comment, and reorder.

All `local` declarations at the top of the function, not inline throughout the body.

Use `local -n` (namerefs, bash 4.3+) for output parameters to avoid stdout pollution and subshell overhead.
See `tmp:make`, `project:detect`, `cmd:get-into` for examples.

## Script Structure (bin/ commands)

Strict ordering, never deviate:

1. Shebang + `set -euo pipefail`
2. Header comment describing purpose
3. Symlink resolution block (identical boilerplate across all scripts)
4. Import block: grouped in `{ }` with `# shellcheck source-path=SCRIPTDIR/../lib` directive
5. Environment validation: `has-min-bash-version` + `has-commands <deps>`
6. Command definition via `cmd:define` / `cmd:*-arg` / `cmd:flag`
7. Constants and parameter globals
8. Functions (named, not inline)
9. `cmd:parse "$@"` + `cmd:validate`
10. Main / dispatch

Subcommand scripts MUST respond to `synopsis` with a one-line description.
`cmd:parse` handles this automatically when using the framework.
Scripts that can't use cmd.sh (like `doctor`, which must work when deps are missing) handle `synopsis` in their manual arg loop.

Subcommand scripts SHOULD be organized into named functions with a thin main block at the bottom.
Code should read like other subcommands - scanning/setup logic in functions, main flow dispatching to those functions.
This makes the script easy to skim: function signatures tell the story, main block shows the flow.

## Library Structure (lib/ files)

Strict ordering:

1. Shebang (`#!/usr/bin/env bash`) - even though libraries are sourced, not executed, the shebang helps editors and shellcheck
2. Header comment describing purpose and scope
3. Multiple-inclusion guard: `[[ "${_INCLUDED_NAME:-}" == "1" ]] && return 0; _INCLUDED_NAME=1`
4. Self-locating scriptdir: `_NAME_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
5. Import block (same `{ }` + shellcheck pattern as bin/)
6. Dependency validation at source time: `has-commands <deps>`
7. Globals (`declare -g` / `declare -gA` / `declare -ga` for associative and indexed arrays)
8. Internal/private functions (underscore-prefixed, NOT exported)
9. Public functions with `export -f` after each function

Libraries MUST NOT have the executable bit set.
The permissions test enforces this.

## Formatting

`shfmt` via `.editorconfig`.
Settings: indent 2 spaces, `binary_next_line`, `switch_case_indent`, `space_redirects`.
`mise run format` formats all tracked shell files.
The `formatting.bats` test fails CI if any file drifts.

`shellcheck -xa` on bin/, helpers/, lib/, test/.
Directives go on the line immediately before the affected statement, with no intervening blank lines.

## Testing (bats)

One `.bats` file per lib or feature, mirroring the `lib/` structure.

Each `@test` is standalone and explicitly named.
No table-driven tests.

Minimal custom helpers: `is()` for equality, `diag()` for diagnostics, `make_stub` / `prepend_stub_path` for command stubbing.
No bats-assert or bats-support plugins.

`setup()` per file.
No `setup_file()`.
No `teardown()` - relies on `BATS_TEST_TMPDIR` lifecycle for cleanup.

Fake repos constructed with `git init` in `$BATS_TEST_TMPDIR`.

Self-reflection tests (lint, formatting, permissions, anti-slop, subcommand-contract) enforce structural conventions at test time.
These catch drift that code review might miss.

### Isolation Guarantees

Unit tests run under `helpers/run-tests` with two layers of isolation:

1. **HOME is a fresh mktemp directory** for the whole run, cleaned up on exit via trap.
   Any code that resolves `~/.config/scratch/...` lands in a throwaway location.
   Individual test files should additionally override `HOME=$BATS_TEST_TMPDIR/home` in `setup()` so cache state never leaks from one test to the next within a run.

2. **A curl network guard** is installed on PATH.
   If a unit test tries to run curl without first stubbing it, the guard fires with a clear error message telling you what to do.

Unit tests MUST NOT hit the network.
External commands (curl, git in certain contexts, gcloud, etc.) must be mocked via `make_stub` (PATH-prepended stub scripts, subprocess-safe) or by overriding a wrapping bash function directly in the test body (simpler when the wrapper is a bash function you control).

Example of function override (the recommended approach when the library under test wraps an external tool in a bash function):

```bash
@test "model:list returns the cached ids" {
  venice:curl() { cat fixture.json; }  # overrides the wrapper, no curl needed
  seed_cache
  run model:list
  ...
}
```

The HOME override is a safety net; the network guard is a safety net; neither replaces good per-test hygiene.

### Verifying stdout and stderr independently

bats's `run` merges stdout and stderr into `$output` by default.
For tests that need to verify *where* output went - especially tests of functions that both produce data on stdout and log to stderr - use `run --separate-stderr`, which puts stderr in `$stderr` and leaves `$output` as pure stdout.

```bash
@test "venice:curl retries and emits warning to stderr" {
  install_multi_curl_stub "429:{}" "200:{\"ok\":true}"
  export SCRATCH_VENICE_MAX_ATTEMPTS=3

  run --separate-stderr venice:curl GET /models
  is "$status" 0
  is "$output" '{"ok":true}'           # pure stdout
  [[ "$stderr" == *"retrying"* ]]      # log messages on stderr
}
```

This is the right pattern whenever you're asserting that something writes to stdout AND logs feedback to stderr.
The merged-output default is fine for tests that only care about one stream.

### Integration Tests

Tests that need to make real API calls go under `test/integration/*.bats` and run via `helpers/run-integration-tests` (or `mise run test:integration`).

Integration tests:
- Are never run in CI.
- Are never part of `mise run test`.
- Still get HOME isolation (so they don't pollute the user's real config).
- Do NOT get the curl network guard.
- Forward `SCRATCH_VENICE_API_KEY` and `VENICE_API_KEY` from the caller's environment.
- MUST call `skip` if no API key is set, so contributors without one still get a green run.
- Run serially - no parallelism against a paid, rate-limited API.

Integration tests are sanity checks: "our request body matches what the API accepts", "our response parser handles real responses", "known error codes come back as expected".
They are not unit tests for logic - that's what the mocked unit tests are for.

## Comments

Describe the code and its purpose, NEVER the change being made.
"AI slop" commentary like "// removed legacy handler" has no place in the code.

Comments should narrate the file: grepping just comments should tell a coherent story.

Encode intention, rationale, and how the code fits the larger system.
Write comments as reference material for a future context-free reader.

TODO/FIXME comments describe the *problem*, not prescribe the solution.
The caller shouldn't dictate implementation to the future implementer.

## Unicode Discipline

No smart quotes, smart apostrophes, or em dashes.
Only ASCII equivalents: `'`, `"`, and `-` for parenthetical asides.

Double-hyphens (` -- `) as faux em dashes are AI slop.
Use a single hyphen (` - `).

The `anti-slop.bats` test scans tracked files and fails if any of these characters appear.

## Markdown (docs, PRs, comments)

One sentence per line.
No mid-sentence wrapping.
Blank line between paragraphs.
Works well across renderers and GitHub's interface.

## Git and Commits

Commit messages are terse fragments, not full sentences.
No AI attribution in commits (no `Co-Authored-By`, no "Generated with Claude Code" footers).

Always create NEW commits rather than amending.

Save-point commits before making code changes if there are unstaged changes.

## Build and Dev Tooling

`mise` is the canonical dev interface.
Tasks: `setup`, `test`, `lint`, `format`, `perms`, `fix`, `check`.
Dev tool versions (shfmt, shellcheck, bats, jq, gum, elixir, erlang) are declared in `.mise.toml`.

`helpers/run-tests` is the test runner.
It detects GNU parallel and uses inter-file parallelism (capped at 8 jobs).

`helpers/setup` handles runtime dep installation (bash 3.2 compatible, called by the entrypoint shim).

## Dependency Declaration

Runtime commands are declared via `has-commands <cmd1> <cmd2>` at library source time or subcommand startup.
The doctor subcommand scans bin/ and lib/ for these declarations and reports status with per-command attribution.

Environment variables are declared via `require-env-vars <VAR1> <VAR2>`.
Same scanning/attribution pattern.

`_INSTALL_HINTS` in `lib/base.sh` maps command names to install hints when they differ from the package name.
