# Architecture

Scratch is a multi-layer bash application with a polyglot embedding pipeline.
This document describes how the pieces fit together.

## Three-Layer Entry Point

The invocation path from shell to running subcommand has three layers.
Each layer has a distinct job and runs under distinct constraints.

### Layer 1: `bin/scratch` (bash 3.2 shim)

The user-facing entry point.
This script MUST remain compatible with bash 3.2 (macOS system default) because its job may be to install bash 5+ when it is missing.

It does four things, in order:

1. Intercepts `scratch setup` and delegates to `helpers/setup`.
2. Verifies the running bash is 5+, prints upgrade instructions if not.
3. Runs `helpers/setup --check` to verify runtime deps; prompts to install if interactive.
4. `exec -a scratch bin/dispatch "$@"` to hand off to the real dispatcher.

`exec -a scratch` sets argv[0] so the process shows up as "scratch" in `ps` / `htop` rather than "dispatch".

The script explicitly forbids bash 4+ features (no associative arrays, no namerefs, no globstar, no `readarray`, no `${var^^}`, no `|&`).
Any bash 4+ syntax here would cause a parse error in bash 3.2 before the version check could run.

### Layer 2: `bin/dispatch` (bash 5+)

The subcommand resolver.
It assumes bash 5+ because the shim guarantees it.

Responsibilities:
- Resolve a subcommand name (`foo`) to its executable (`bin/scratch-foo`).
- Build the top-level help by calling `scratch-<name> synopsis` on each subcommand and rendering the result through `tui:format`.
- Wire built-in meta-commands (`help`, `-h`, `--help`).
- Execute the resolved subcommand with `exec`.

### Layer 3: `bin/scratch-<name>` (individual subcommands)

The actual command implementations.
Each script declares its own interface via `cmd.sh`, sources its own libraries, and runs its own logic.

Subcommands MUST respond to `synopsis` with a one-line description on stdout (this is what dispatch calls to build the help menu).
`cmd.sh` handles this automatically; scripts that can't use `cmd.sh` (doctor) handle it in their manual arg loop.

## Directory Structure

```
bin/          user-facing executables
  scratch         entry point shim (bash 3.2)
  dispatch        subcommand dispatcher (bash 5+)
  scratch-doctor  env health check
  scratch-project project management CRUD

lib/          sourced libraries (not executable)
  base.sh         warn, die, has-commands, require-env-vars
  termio.sh       io:is-tty, io:sedl, io:strip-ansi, etc.
  tui.sh          tui:log, tui:format, tui:spin, tui:choose (gum wrappers)
  tempfiles.sh    tmp:make, tmp:cleanup (trap-based temp file registry)
  project.sh      project:save, project:load, project:detect (worktree-aware)
  cmd.sh          cmd:define, cmd:parse, cmd:get (declarative command framework)

libexec/      internal executables called only by other scripts
  embed.exs       Elixir embedding generator (called by helpers/embed)

helpers/      user-callable helper scripts
  setup           runtime dep installer (bash 3.2 compatible)
  run-tests       clean-env bats runner with parallel support
  embed           bash wrapper around libexec/embed.exs (sets CXX for EXLA)

test/         bats test suite
  helpers.sh        is, diag, make_stub, prepend_stub_path
  base.bats         tests for lib/base.sh
  cmd.bats          tests for lib/cmd.sh
  project.bats      tests for lib/project.sh
  scratch-doctor.bats
  lint.bats               self-reflection: shellcheck
  formatting.bats         self-reflection: shfmt drift
  permissions.bats        self-reflection: +x policy
  anti-slop.bats          self-reflection: no smart quotes or em dashes
  subcommand-contract.bats  self-reflection: subcommands honor --help

docs/
  guides/     user-facing documentation
  dev/        developer- and LLM-facing documentation

.mise.toml    dev tool versions and tasks
.editorconfig shfmt formatting rules
```

## Layer Separation Rules

- `bin/` files are executables.
  They MUST have the `+x` bit set.
  Directly invocable by users.

- `lib/` files are sourced, never executed.
  They MUST NOT have the `+x` bit set.
  Each has a multiple-inclusion guard.

- `helpers/` files are user-callable scripts (`scratch setup`, `scratch run-tests` patterns).
  They MUST have the `+x` bit set.

- `libexec/` files are internal implementation details, called only by other scripts.
  They MUST NOT have the `+x` bit set.
  They're not meant to be invoked directly; a wrapper in `helpers/` or `bin/` handles environment setup.

The `permissions.bats` test enforces these rules at test time.

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

## Dependency Declaration and Doctor

The doctor subcommand is a declarative dependency checker.
It scans `bin/` and `lib/` for `has-commands` and `require-env-vars` declarations, then verifies each one and reports status with per-command attribution.

Doctor is intentionally independent of `cmd.sh`, `tui.sh`, and `gum`.
It uses raw ANSI via `printf` because its whole purpose is to run when dependencies are broken.
It DOES respect TTY detection: ANSI codes are auto-suppressed when stdout is piped.

The scanner keywords (`has-commands`, `require-env-vars`) are held in variables inside doctor to prevent the scanner from matching its own grep arguments.

## Self-Reflection Tests

Several bats files exist solely to enforce structural conventions:

- `lint.bats` - shellcheck on bin/, helpers/, lib/, test/
- `formatting.bats` - fails if shfmt would change any tracked file
- `permissions.bats` - enforces +x on bin/helpers, -x on lib/libexec
- `anti-slop.bats` - fails if smart quotes or em dashes appear anywhere in tracked files
- `subcommand-contract.bats` - verifies every subcommand honors `--help` with exit 0

These tests catch drift that code review might miss.
They run under the same `env -i` harness as functional tests via `helpers/run-tests`.
