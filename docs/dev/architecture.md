# Architecture

Scratch is a multi-layer bash application with a polyglot embedding pipeline.
This document describes how the pieces fit together.

## Entry Point and the Subcommand System

The invocation path from shell to running subcommand is a chain of execs.
Each level has a distinct job and runs under distinct constraints.

### The Shim: `bin/scratch` (bash 3.2)

The user-facing entry point.
This script MUST remain compatible with bash 3.2 (macOS system default) because its job may be to install bash 5+ when it is missing.

It does four things, in order:

1. Intercepts `scratch setup` and delegates to `helpers/setup`.
2. Verifies the running bash is 5+, prints upgrade instructions if not.
3. Runs `helpers/setup --check` to verify runtime deps; prompts to install if interactive.
4. `exec -a scratch helpers/root-dispatcher "$@"` to hand off to the real dispatcher.

`exec -a scratch` sets argv[0] so the process shows up as "scratch" in `ps` / `htop` rather than "root-dispatcher".

The script explicitly forbids bash 4+ features (no associative arrays, no namerefs, no globstar, no `readarray`, no `${var^^}`, no `|&`).
Any bash 4+ syntax here would cause a parse error in bash 3.2 before the version check could run.

### Root Dispatcher: `helpers/root-dispatcher` (bash 5+)

The target of the shim's `exec`.
Lives in `helpers/` rather than `bin/` so that `dispatch:list "scratch"` (which globs `bin/scratch-*`) does not accidentally see it as a child of itself.

Its job is trivial: try `dispatch:try "scratch" "$@"` to resolve the first arg to a subcommand binary and exec it.
If that returns (no match, `--help`, or no args), it prints the top-level usage via `dispatch:usage` and exits.

This is intentionally the same shape as any other parent command (see below).
It has no behavior of its own; it is a generic dispatcher parameterized with the prefix `"scratch"`.

### Parent Commands: `bin/scratch-<name>` with children

A "parent" is a subcommand binary that itself has children.
`bin/scratch-project` is the first example.

A parent command has this shape:

```bash
# Respond to synopsis fast, before loading libraries
if [[ "${1:-}" == "synopsis" ]]; then
  printf '%s\n' "Manage project configurations"; exit 0
fi

# ... symlink resolution ...
# ... source libs including dispatch.sh ...

# Try to dispatch to a child
dispatch:try "scratch-project" "$@" || true

# Fallthrough: no child matched. Usage + exit.
dispatch:usage "scratch-project" "Manage project configurations"
```

Because `dispatch:try` returns non-zero on no-match, parents are free to do whatever they want in the fallthrough: print usage (the common case), run a default action, show a dancing ASCII hamster, etc.

### Leaf Commands: `bin/scratch-<parent>-<verb>`

A "leaf" is a subcommand binary with no children.
It's a normal command script that uses `cmd.sh` to declare its interface and parse its own argv.

Naming rule: each hyphen in a binary name is a level separator.
`bin/scratch-project-list` is a child of `scratch-project`, which is a child of `scratch`.
This means subcommand verb names cannot contain hyphens.

`dispatch:list` enforces this: when globbing children of prefix P, it only includes binaries whose verb (basename minus `P-`) contains no further hyphens.
That way `dispatch:list "scratch"` yields `[doctor, project, ...]` but NOT `[doctor, project, project-list, project-show, ...]`.

### Synopsis Protocol

Every subcommand binary (parent or leaf) MUST respond to the single argument `synopsis` by printing its one-line description on stdout and exiting 0.
`dispatch:usage` calls this to build the subcommand listing.

For leaves using `cmd.sh`, this is handled automatically by `cmd:parse`.
For parents and for commands that bypass `cmd.sh` (like `doctor`), handle synopsis manually BEFORE sourcing any libraries so the response stays fast.

### The `help` Verb

`scratch help <verb>` walks the tree.
`dispatch:try` intercepts the literal token `help` and, if followed by a known verb, execs that verb's binary with `--help`.
This works at any level: `scratch project help list` runs `scratch-project-list --help`.

## Directory Structure

```
bin/          user-facing subcommand executables
  scratch                  entry point shim (bash 3.2)
  scratch-doctor           env health check (leaf)
  scratch-project          project management (parent dispatcher)
  scratch-project-list     leaf
  scratch-project-show     leaf
  scratch-project-create   leaf
  scratch-project-edit     leaf
  scratch-project-delete   leaf

lib/          sourced libraries (not executable)
  base.sh         warn, die, has-commands, require-env-vars
  termio.sh       io:is-tty, io:sedl, io:strip-ansi, etc.
  tui.sh          tui:log, tui:format, tui:spin, tui:choose (gum wrappers)
  tempfiles.sh    tmp:make, tmp:cleanup (trap-based temp file registry)
  project.sh      project:save, project:load, project:detect (worktree-aware)
  cmd.sh          cmd:define, cmd:parse, cmd:get (declarative command framework)
  dispatch.sh     dispatch:try, dispatch:usage (parameterized subcommand dispatch)
  venice.sh      venice:api-key, venice:curl (Venice API primitives)
  model.sh       model:fetch, model:list, model:exists, model:jq (registry) +
                  model:profile:* (profile system, sourced from data/models.json)
  chat.sh        chat:completion, chat:extract-content (chat completions)

libexec/      internal non-bash executables
  embed.exs       Elixir embedding generator (called by helpers/embed)

data/         static config data shipped in the repo (not user settings)
  models.json     model profile definitions (smart/balanced/fast bases +
                  coding/web variants), read by lib/model.sh's
                  model:profile:* functions

helpers/      bash scripts that are not subcommands
  setup                  runtime dep installer (bash 3.2 compatible)
  run-tests              clean-env bats runner with HOME isolation + curl guard
  run-integration-tests  real-API runner (no curl guard; forwards API key)
  embed                  bash wrapper around libexec/embed.exs (sets CXX for EXLA)
  root-dispatcher        target of bin/scratch exec; top-level subcommand dispatcher

test/         bats test suite (unit tests only - non-recursive)
              Files use 2-digit numerical prefixes (CPAN convention) so
              they run in dependency order. Lib tests come first, bin
              tests next, self-reflection tests last.
  helpers.sh                   is, diag, make_stub, prepend_stub_path
  00-base.bats                 tests for lib/base.sh
  01-cmd.bats                  tests for lib/cmd.sh
  02-dispatch.bats             tests for lib/dispatch.sh
  03-project.bats              tests for lib/project.sh
  04-venice.bats               tests for lib/venice.sh
  05-model.bats                tests for lib/model.sh (registry + profiles)
  06-chat.bats                 tests for lib/chat.sh
  10-scratch-doctor.bats       tests for bin/scratch-doctor
  90-lint.bats                 self-reflection: shellcheck
  91-formatting.bats           self-reflection: shfmt drift
  92-permissions.bats          self-reflection: +x policy
  93-anti-slop.bats            self-reflection: unicode + AI attribution
  94-subcommand-contract.bats  self-reflection: subcommands honor --help

test/integration/   bats tests that hit the REAL venice API (opt-in only)
  00-venice.bats    end-to-end smoke tests for venice + model + chat

docs/
  guides/     user-facing documentation
  dev/        developer- and LLM-facing documentation

.mise.toml    dev tool versions and tasks
.editorconfig shfmt formatting rules
```

## Layer Separation Rules

- `bin/` files are subcommand executables.
  They MUST have the `+x` bit set.
  Named with the `scratch-` prefix (and `scratch-parent-verb` for leaves).
  Directly invocable by users via the dispatcher.

- `lib/` files are sourced, never executed.
  They MUST NOT have the `+x` bit set.
  Each has a multiple-inclusion guard.

- `helpers/` files are bash scripts that are NOT subcommands.
  They MUST have the `+x` bit set.
  This includes both user-callable scripts (`setup`, `run-tests`, `embed`) and internal targets of the shim (`root-dispatcher`).
  They are kept out of `bin/` so they don't accidentally appear in `dispatch:list "scratch"` output.

- `libexec/` files are internal non-bash executables (e.g., Elixir scripts).
  They MUST NOT have the `+x` bit set.
  A wrapper in `helpers/` handles environment setup and execs them with the right interpreter.

- `data/` files are static config data shipped with the repo (e.g., model profile definitions in `data/models.json`).
  They MUST NOT have the `+x` bit set.
  Tracked in git, updated via code changes, never written by scratch at runtime.
  This is distinct from `~/.config/scratch/...` which is the user's runtime config and IS written by scratch.

The `92-permissions.bats` test enforces these rules at test time.

## The Library Stack

Libraries form a dependency graph.
`base.sh` is the root; everything else can depend on it.

```
base.sh              (no deps)
  |
  +-- termio.sh      (depends on base)
  |     |
  |     +-- tui.sh   (depends on base + termio, requires gum)
  |
  +-- tempfiles.sh   (depends on base, optionally uses tui)
  |
  +-- project.sh     (depends on base, requires jq)
  |
  +-- cmd.sh         (depends on base ONLY)
  |
  +-- dispatch.sh    (depends on base ONLY; optionally uses tui:format at runtime)
  |
  +-- venice.sh      (depends on base, requires curl + jq)
        |
        +-- model.sh (depends on base + venice, requires jq)
        |
        +-- chat.sh  (depends on base + venice, requires jq)
```

`cmd.sh` deliberately does not source `tui.sh` at load time, because tui.sh requires `gum` and `jq` at source time.
This would make even the fast `synopsis` path depend on those binaries.
Instead, `cmd:usage` checks for `tui:format` lazily via `type -t` and falls back to plain `cat` when rendering help.

## The Command Framework (cmd.sh)

`cmd.sh` provides a declarative API for defining subcommand interfaces.
Scripts register their arguments and flags up front, then call `cmd:parse "$@"` to handle argv.

### Lifecycle

```
cmd:define / cmd:*-arg / cmd:flag / cmd:define-cli-usage   (registration)
                          |
                    cmd:parse "$@"                         (parse + meta-commands)
                          |
                    cmd:validate                           (check required args)
                          |
                    cmd:get / cmd:has / cmd:get-into       (retrieve values)
```

### Meta-commands

`cmd:parse` intercepts three meta-commands that cause an immediate exit:

- `synopsis` - prints the one-line description and exits 0 (used by dispatch to build help)
- `--help` / `-h` / `help` - prints formatted usage via `cmd:usage` and exits 0

### Typed Arguments

Argument types are metadata for help rendering; they are not enforced at parse time.
Available registration functions:

- `cmd:required-arg LONG SHORT DESC TYPE [ENUM]` - required named arg
- `cmd:optional-arg LONG SHORT DESC TYPE DEFAULT [ENUM]` - optional named arg with default
- `cmd:flag LONG SHORT DESC` - boolean flag (default off)
- `cmd:optional-value-arg LONG SHORT DESC TYPE` - flag that optionally consumes a value (three states: not passed / bare / with value)

### Help Rendering

`cmd:usage` builds a markdown help page and pipes it through `_cmd:format_help`, which uses `tui:format` when available.
The page has USAGE, SYNOPSIS, OPTIONS (two-column aligned), ENV VARS (two-column aligned if any), and extra sections from `cmd:define-cli-usage`.
Any accumulated errors from parsing or validation are appended as an ERRORS section and the script exits 1.

## The Embedding Pipeline

`helpers/embed` is a bash wrapper that execs `libexec/embed.exs` (Elixir).
The wrapper exists solely to set `CXX` with the clang workaround before Elixir starts - an Elixir script can't set environment variables that affect its own process's compilation.

The Elixir script uses Bumblebee + EXLA to load `sentence-transformers/all-MiniLM-L12-v2` and produce 384-dimensional embeddings.
Input comes from a file argument or stdin (`-`).
Output is a JSON array of floats on stdout.
The model is cached under `~/.config/scratch/models/` via `BUMBLEBEE_CACHE_DIR`.

EXLA is pinned to `0.9.2` to avoid a duplicate-symbol linker bug in 0.10.0.
See `libexec/embed.exs` for the full compilation notes.

## Project Configuration

A "project" in scratch is a named directory association.
Projects live under `~/.config/scratch/projects/<name>/settings.json` with keys:

- `root` (string) - absolute path to the project
- `is_git` (bool) - whether the root is a git repository
- `exclude` (array of strings) - glob patterns to exclude

`lib/project.sh` provides the API.
`project:detect` resolves the current working directory to a known project, including worktree awareness: if cwd is inside a git worktree, it traces back to the main repo via `git rev-parse --git-common-dir` vs `--git-dir` comparison, then matches against configured projects.
Multi-return functions use bash namerefs (`local -n`).

`bin/scratch-project` provides CRUD: `list`, `show`, `create`, `edit`, `delete`.
Interactive commands use `gum` for input and confirmation.

## Venice Integration (venice.sh, model.sh, chat.sh)

Scratch talks to [Venice.ai](https://docs.venice.ai) via a three-layer library stack.
The split keeps HTTP plumbing, registry caching, and chat request shaping each in their own place.

### `lib/venice.sh` - the foundation

Owns API key resolution, the base URL, and the `venice:curl` wrapper.

Key resolution tries `SCRATCH_VENICE_API_KEY` first, then `VENICE_API_KEY`.
The `SCRATCH_` prefix lets a contributor override the general key for scratch-specific work without touching their shell profile.
Dies with a clear message if neither is set.

`venice:curl METHOD PATH [BODY]` injects the `Authorization: Bearer $key` header, posts the body via stdin (`-d @-`) to avoid argv length limits, writes the response body to a temp file (`-o`) and captures the status code (`-w '%{http_code}'`) separately.
Venice's documented error codes (401, 402, 429, 503, 504) get translated into user-targeted `die` messages: "insufficient credits, top up at...", "rate limited, wait and retry", etc.

Transient errors (429, 503, 504) are automatically retried up to `SCRATCH_VENICE_MAX_ATTEMPTS` times (default 3) with a log10 backoff between attempts.
The backoff formula is `ceil(2 * (1 + log10(attempt)))`, which ramps quickly from the start - the first retry is a real 2-second wait - but self-caps: even 1000 failed attempts only reaches an 8-second delay.
Log10 is a better shape here than exponential for two reasons: it starts with a meaningful delay instead of fractional seconds, and it implicitly bounds the worst-case wait rather than requiring an arbitrary clamp.
Each retry logs a warn to stderr so long pauses have visible cause.
Non-retryable errors (401, 402, 415, other 4xx) die immediately without retrying, since retrying cannot fix them.

### `lib/model.sh` - the registry cache

The model list is cached as the raw Venice response at `~/.config/scratch/venice/models.json`.
`model:fetch` always requests `?type=all` so one call populates everything.
Writes are atomic (`.tmp` then `mv`) so a failed fetch never corrupts a previously-good cache.

All read functions (`model:list`, `model:get`, `model:exists`, `model:jq`) lazy-load the cache through a private `_model:ensure-cache` helper.
First use from a fresh install triggers the fetch automatically.
No TTL - the cache persists until the user calls `model:fetch` again to refresh.

`model:jq ID EXPR` takes an arbitrary jq expression rooted at a single model's object.
This is the escape hatch for reading capability flags without writing wrapper functions for every field.

### `lib/chat.sh` - chat completions

`chat:completion MODEL MESSAGES_JSON [EXTRA_JSON]` is the whole API.
Callers build messages as JSON themselves (via jq, heredocs, or literal strings) and pass optional extras that get shallow-merged into the request body.
That way the library has no opinion about temperature, venice_parameters, tools, response_format, or any of the other request fields - callers just pass them in `EXTRA_JSON`.

`chat:extract-content` is stdin-oriented so it composes in pipelines:

```bash
chat:completion "$model" "$messages" | chat:extract-content
```

The `// ""` fallback in its jq expression means tool-call responses (where `.choices[0].message.content` is null) return an empty string instead of the literal text "null".

## Test Isolation

Unit tests run under `helpers/run-tests` with two isolation guarantees:

1. **HOME is a fresh mktemp directory** for the whole run, cleaned up on exit via trap.
   Any code that resolves `~/.config/scratch/...` lands in a throwaway location and cannot touch the developer's real config.
   Individual test files additionally override `HOME=$BATS_TEST_TMPDIR/home` per test so cache state never leaks from one test to the next.

2. **A curl network guard** is installed on PATH.
   The guard is a curl stub that exits non-zero with a loud error message pointing the test writer at `docs/dev/conventions.md`.
   Per-test stubs made via `make_stub` prepend `BATS_TEST_TMPDIR/stubbin` ahead of the guard, so tests that legitimately mock curl override transparently.

Neither guarantee applies to integration tests.
Integration tests run under `helpers/run-integration-tests`, which:

- Still isolates HOME to a tmpdir (prevents polluting the user's real venice model cache).
- Does NOT install the curl guard (integration tests hit the real network by definition).
- Forwards `SCRATCH_VENICE_API_KEY` and `VENICE_API_KEY` from the caller's environment.
- Runs serially - no parallelism against a paid, rate-limited API.

Integration tests are never run in CI and never part of `mise run test`.
Opt in via `mise run test:integration` or call the runner directly.
Individual tests `skip` cleanly if no API key is set, so contributors without one still get a green run with a "skipped all" result.

## Dependency Declaration and Doctor

The doctor subcommand is a declarative dependency checker.
It scans `bin/`, `lib/`, and `helpers/` for `has-commands` and `require-env-vars` declarations, then verifies each one and reports status with per-command attribution.

Doctor is intentionally independent of `cmd.sh`, `tui.sh`, and `gum`.
It uses raw ANSI via `printf` because its whole purpose is to run when dependencies are broken.
It DOES respect TTY detection: ANSI codes are auto-suppressed when stdout is piped.

The scanner keywords (`has-commands`, `require-env-vars`) are held in variables inside doctor to prevent the scanner from matching its own grep arguments.

### Rule: every non-POSIX tool gets a declaration

If a script shells out to a tool that isn't guaranteed by POSIX, it MUST declare it via `has-commands` somewhere doctor can scan.
Never rely on git/jq/curl/gum/bc/etc. being "obviously" present - declare and let the scanner find it.
The only exception is tools used optionally with a graceful fallback (e.g. `stdbuf` in `lib/termio.sh` - the fallback is passthrough, so declaring would defeat the design).

The three scan sets have different attribution labels:
- `bin/scratch-<verb>` declarations attribute to the verb name
- `lib/*.sh` declarations attribute to the synthetic label `lib` (library deps apply transitively to many commands)
- `helpers/<name>` declarations attribute to the helper's basename (e.g., `helpers/embed` -> `embed`)

When you add a new tool to scratch:
1. If it goes in a library, declare it in that library's source-time `has-commands` line.
2. If it's specific to one subcommand, declare it at the top of that subcommand's script.
3. If it's specific to one helper, declare it at the top of that helper.
4. If it's a runtime dep that `scratch setup` should install, also add it to `helpers/setup`'s `RUNTIME_DEPS` list.

## Self-Reflection Tests

Several bats files exist solely to enforce structural conventions:

- `90-lint.bats` - shellcheck on bin/, helpers/, lib/, test/
- `91-formatting.bats` - fails if shfmt would change any tracked file
- `92-permissions.bats` - enforces +x on bin/helpers, -x on lib/libexec/data
- `93-anti-slop.bats` - fails on smart quotes, em dashes, or AI attribution in unpushed commits
- `94-subcommand-contract.bats` - verifies every subcommand honors `--help` with exit 0

These tests catch drift that code review might miss.
They run under the same `env -i` harness as functional tests via `helpers/run-tests`.
