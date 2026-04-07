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

## LLM Tool Structure (tools/ directory)

The `tools/` directory is **reserved for LLM tool calling**. Do not park unrelated scripts here. If you need a general-purpose script, it goes in `helpers/` (if it's a dev/build helper) or as a `bin/scratch-<verb>` subcommand (if it's a user-facing command).

Each tool is a self-contained directory under `tools/<name>/` with three required files. The format borrows from fnord's "frob" system, with one scratch-specific addition.

```
tools/<name>/
  spec.json     OpenAI function calling spec - the inner {name, description, parameters} object
  main          executable, any language; receives args via SCRATCH_TOOL_ARGS_JSON env var
  is-available  bash; runtime gate AND dependency manifest (see below)
```

Naming: tool names match `^[a-z][a-z0-9_-]*$`. The directory basename must equal the spec.json `.name` field. Both rules are enforced by `test/95-tool-contract.bats`.

Output semantics: exit 0 + stdout content goes to the LLM as the tool result. Non-zero exit + stderr content goes to the LLM as the failure result. Strict separation, no merging. This lets tools write progress notes to stderr without polluting their success output.

The environment contract for `main` (set by `tool:invoke`):
- `SCRATCH_TOOL_ARGS_JSON` - the LLM's argument object as JSON (always set; `{}` for no-arg tools)
- `SCRATCH_TOOL_DIR` - the tool's own directory
- `SCRATCH_HOME` - scratch repo root (so bash tools can `source "$SCRATCH_HOME/lib/..."`)
- `SCRATCH_PROJECT` and `SCRATCH_PROJECT_ROOT` - only set if `project:detect` succeeds

### `is-available` is double-duty: runtime gate AND dependency manifest

This is the scratch-specific addition to fnord's frob format and the rule that makes the tool subsystem self-documenting.

Every tool's `is-available` script MUST:

1. Source `lib/base.sh` (using `$SCRATCH_HOME` to locate it).
2. Call `has-commands` for every external program the tool needs.

Same line does both jobs:

- **At runtime,** `has-commands` actually verifies the tool's dependencies are present and dies with the standard install hint if any are missing.
- **At doctor scan time,** the textual scanner finds the `has-commands` line and attributes the declared commands to `tool:<name>` in the doctor's report. No separate registration step.

Without the source line, `has-commands` would be undefined and the script would fail. Without the `has-commands` call, the script would be a no-op gate (passing always) AND the doctor would have nothing to discover. Both are wrong; the contract test enforces both properties.

Example (`tools/notify/is-available`):

```bash
#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$SCRATCH_HOME/lib/base.sh"

# notify wraps tui:* (which uses gum) and parses args via jq.
has-commands gum jq
```

After this lands, `scratch doctor` shows `gum  (lib tool:notify)` - automatic combined attribution from both the lib stack and the notify tool, no manual registration anywhere.

### Tool naming and reserved directory

The `tools/` directory is generic-sounding but **reserved for LLM tools only**. Don't add general scripts there. The reasons:

1. `dispatch:list` and the doctor scanner walk `tools/*` expecting the three-file contract.
2. `test/95-tool-contract.bats` will fail loudly on any directory that doesn't match.
3. Future tooling (agents, gating, sandboxing) will assume everything under `tools/` is an LLM tool.

If you want to add a general script, use `helpers/` (dev/build helper) or `bin/scratch-<verb>` (user-facing command).

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

**Rule:** every non-POSIX tool that a script invokes MUST be declared via `has-commands` somewhere doctor can scan.

This is not a nice-to-have.
It guarantees that:

- Missing tools produce the `has-commands` error message (with install hint) instead of a cryptic `command not found` in the middle of a function.
- `scratch doctor` can give users a pre-flight checklist of what's installed and what isn't, with per-command attribution showing which scratch component needs each tool.
- Adding or removing functionality automatically updates the reported dependency surface, since declarations track real usage.

Runtime commands are declared via `has-commands <cmd1> <cmd2>` at library source time, at the top of a subcommand/helper script, or in an LLM tool's `is-available` script.
Doctor scans `bin/`, `lib/`, `helpers/`, and `tools/<name>/is-available` for these declarations, attributing them to the file's component (subcommand verb, `lib`, helper basename, or `tool:<name>`).

Environment variables are declared via `require-env-vars <VAR1> <VAR2>`.
Same scanning/attribution pattern.

`_INSTALL_HINTS` in `lib/base.sh` maps command names to install hints when they differ from the package name (e.g., `gcloud` installs via `brew install google-cloud-sdk`).

### Exception: optional tools with a graceful fallback

If a tool is used optionally with a graceful fallback (e.g. `stdbuf` in `lib/termio.sh`, where the fallback is a passthrough), do NOT declare it via `has-commands`.
Declaring would trigger a die at source time, defeating the fallback.
Add a comment explaining why the tool is not declared.

### POSIX tools

POSIX-guaranteed commands do not need declarations: `sh`/`bash`, `printf`, `echo`, `cat`, `cp`, `mv`, `rm`, `mkdir`, `grep`, `sed`, `awk`, `tr`, `cut`, `sort`, `head`, `tail`, `wc`, `find`, `test`, `basename`, `dirname`, `pwd`, `cd`, `mktemp`, `chmod`, `readlink`, `env`, `sleep`, `kill`, `trap`, etc.
When in doubt, declare.
The cost of a spurious declaration is one line; the cost of a missing one is a user hitting an unfriendly error.

### POSIX features within POSIX tools

Stay inside POSIX feature sets when using POSIX tools.
The tool being POSIX does not mean every flag and regex syntax is.

Specifically for `grep` and `sed`:
- Use POSIX character classes (`[[:space:]]`, `[[:alpha:]]`, `[[:digit:]]`, etc.) instead of GNU/Perl backslash shortcuts (`\s`, `\w`, `\d`).
  The character class form works on every POSIX-compliant grep and sed; the backslash form is silently undefined on BSD grep.
- Use BRE (basic regular expressions) by default; switch to ERE with `grep -E` or `sed -E` when needed.
  Avoid `grep -P` (PCRE - GNU only) and `sed -E -i ''` (BSD/GNU `-i` divergence).
- `grep -h`, `grep -v`, `grep -c`, `grep -l`, `grep -F`, `grep -E` are all POSIX. `grep -P`, `grep -z`, `grep -o` (some flag combinations) are GNU extensions.

If you ever genuinely need a GNU-only feature, prefer adding a small wrapper function (the `gnu-grep` pattern) that aliases to `ggrep` on macOS and `grep` on Linux, rather than declaring `has-commands grep` and pretending it's enough.
For complex pattern work where ripgrep or silver searcher would be more readable, prefer `ag` (silver searcher) over `rg` (ripgrep) - ag is friendlier in scripting contexts (rg's directory exclusion semantics are awkward).
