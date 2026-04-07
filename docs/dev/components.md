# Components Reference

Per-component reference for libraries and subcommands.
For cross-component architecture, see `architecture.md`.
For coding conventions, see `conventions.md`.

## Libraries

### `lib/base.sh`

The foundation library.
No dependencies, no imports.
Everything else can depend on this.

Functions:
- `warn MSG` - write to stderr
- `die MSG` - warn + `return 1` (not `exit 1`, so it composes with `set -e`)
- `has-min-bash-version [MAJOR[.MINOR]]` - enforce minimum bash version (default 5.0), exits with install hints on failure
- `has-commands CMD1 CMD2 ...` - verify commands exist in PATH, dies with install hint on failure
- `require-env-vars VAR1 VAR2 ...` - verify env vars are set and non-empty

Globals:
- `_INSTALL_HINTS` - associative array mapping command names to install hints when they differ from the package name

### `lib/termio.sh`

Terminal I/O primitives.
Depends on `base.sh`.

Functions:
- `io:is-tty [FD]` - test if the given fd is a terminal (default stdout)
- `io:autoflush CMD ARGS...` - run CMD with line-buffered stdout/stderr via stdbuf (passthrough if stdbuf is missing)
- `io:sedl REGEX` - line-buffered sed with extended regex (BSD `-l` or GNU stdbuf wrap)
- `io:trim` - trim whitespace, skip empty lines
- `io:strip-ansi` - remove ANSI escape codes
- `io:strip-ansi-notty` - strip ANSI only when stdout is not a TTY
- `io:has-flag FLAG ARGS...` - test if FLAG appears in ARGS
- `io:is-non-empty MSG` - die with MSG if stdin is empty, otherwise pass through

### `lib/tui.sh`

User-interface wrappers around `gum`.
Depends on `base.sh` and `termio.sh`.
Requires `gum` at source time.

Functions:
- `tui:log LEVEL [ARGS...]` - structured log via `gum log`; when stdin is a pipe, reads line-by-line
- `tui:debug` / `tui:info` / `tui:warn` / `tui:error` - level-specific shortcuts
- `tui:die MSG [FIELDS...]` - log error, then die
- `tui:format` - markdown via `gum format` on TTY, cat otherwise
- `tui:spin TITLE` - spinner via `gum spin --show-stdout` for a piped command
- `tui:choose VAR HEADER PROMPT [FLAGS...]` - fuzzy picker via `gum filter`; result into nameref VAR
- `tui:choose-one VAR HEADER PROMPT [FLAGS...]` - single-selection variant

### `lib/tempfiles.sh`

In-memory temp file registry with trap-based cleanup.
Depends on `base.sh`.
Optionally uses `tui:debug` for logging if available.

Functions:
- `tmp:track PATH` - register a path for cleanup
- `tmp:make VAR TEMPLATE [MKTEMP_ARGS...]` - create a temp file via `mktemp`, register it, assign the path to nameref VAR (NOT via `$(...)` - that would lose the registration in the subshell)
- `tmp:cleanup` - best-effort deletion of all tracked files
- `tmp:install-traps` - install EXIT/INT/TERM/HUP traps that call `tmp:cleanup`, chaining with any existing handlers

Globals:
- `SCRATCH_TMPFILES` - registered paths
- `_TMPFILES_TRAPS_INSTALLED` - guard to prevent duplicate trap registration

### `lib/project.sh`

Project configuration management.
Depends on `base.sh`.
Requires `jq` at source time.

Functions:
- `project:config-dir NAME` - print `~/.config/scratch/projects/<name>/`
- `project:config-path NAME` - print the settings.json path
- `project:exists NAME` - return 0 if the project has a settings.json
- `project:list` - print all configured project names (one per line)
- `project:save NAME ROOT IS_GIT [EXCLUDE...]` - write settings.json
- `project:load NAME OUT_ROOT OUT_IS_GIT OUT_EXCLUDE` - read settings.json into namerefs
- `project:delete NAME` - remove the project directory
- `project:detect OUT_NAME OUT_IS_WORKTREE` - resolve cwd to a known project, setting worktree flag if applicable

Worktree detection compares `git rev-parse --git-dir` with `--git-common-dir`.
If they differ, cwd is in a worktree and the common dir's parent is the main repo root.

Globals:
- `SCRATCH_CONFIG_DIR` - `~/.config/scratch`
- `SCRATCH_PROJECTS_DIR` - `~/.config/scratch/projects`

### `lib/dispatch.sh`

Parameterized subcommand dispatch.
Depends on `base.sh` only.
Optionally uses `tui:format` at runtime (via `type -t` check) for markdown rendering in `dispatch:usage`.

Functions:
- `dispatch:list PREFIX` - print verb names of all direct-child subcommands of PREFIX, sorted, one per line (grandchildren excluded via the "no hyphens in verb" rule)
- `dispatch:path PREFIX VERB` - print the absolute path to the binary implementing VERB under PREFIX; returns 1 if not found
- `dispatch:usage PREFIX DESC` - render a markdown help page to stderr listing all direct children with their synopsis lines
- `dispatch:try PREFIX "$@"` - resolve first non-flag arg to a child subcommand and exec it; returns 1 on no match so the caller can handle fallthrough
- `dispatch:bindir` - (private) print the absolute path to `bin/`

`dispatch:try` handles these special cases without execing:
- `-h` / `--help` - returns 1 (caller prints usage)
- `help <verb>` - execs `<verb> --help` (walks the tree)
- `synopsis` - returns 1 (caller must handle synopsis itself before calling)

See the "Entry Point and the Subcommand System" section in `architecture.md` for the full design.

### `lib/cmd.sh`

Declarative command definition framework.
Depends on `base.sh` only (not `tui.sh`, to avoid pulling in gum for the fast synopsis path).

Registration functions (call during setup):
- `cmd:define NAME DESC` - command name and one-line description
- `cmd:required-arg LONG SHORT DESC TYPE [ENUM]` - required named arg
- `cmd:optional-arg LONG SHORT DESC TYPE DEFAULT [ENUM]` - optional named arg
- `cmd:flag LONG SHORT DESC` - boolean flag
- `cmd:optional-value-arg LONG SHORT DESC TYPE` - flag that optionally consumes a value
- `cmd:define-cli-usage HEADER CONTENT` - extra help section
- `cmd:define-env-var VAR DESC [DEFAULT]` - documented env var

Runtime functions (call after registration):
- `cmd:parse "$@"` - parse argv, handle synopsis/--help meta-commands
- `cmd:validate` - check required args, return 0 if clean
- `cmd:get LONG` - print parsed value
- `cmd:get-into VAR LONG` - assign parsed value to nameref VAR
- `cmd:has LONG` - test if flag was passed
- `cmd:rest` - print positional args
- `cmd:usage [--no-extra]` - print help and exit

See `test/cmd.bats` for examples of every function.

## Subcommands

### `bin/scratch-doctor`

Environment health check.
Intentionally independent of `cmd.sh`, `tui.sh`, and `gum` - it must work when dependencies are broken.
Uses raw ANSI `printf` with TTY detection for output.

Checks:
- bash version (5+)
- All commands declared via `has-commands` in bin/ and lib/
- All env vars declared via `require-env-vars` in bin/ and lib/
- Dev tools from `.mise.toml` + GNU parallel (with `--dev`)

Flags:
- `--fix` - prompt to install missing deps via `helpers/setup`
- `--dev` - also check developer tools

The scanner reads files with `grep` and strips the keyword prefix to extract command/env names.
Keywords are held in variables (`_KW_HAS_CMD`, `_KW_REQ_ENV`) so the literal strings never appear in code lines that would otherwise match the scanner's own grep.

### `bin/scratch-project` (parent)

Parent dispatcher for project management.
Has no behavior of its own - delegates to leaves via `dispatch:try`, falling through to `dispatch:usage` if no child matched.

### `bin/scratch-project-list` (leaf)

Prints all configured projects with their root paths.
Uses `cmd.sh` for the interface, `project:list` + `project:load` for data.

### `bin/scratch-project-show` (leaf)

Prints a single project's configuration.
Takes an optional positional NAME; if omitted, auto-detects via `project:resolve-name` (which falls back to `project:detect` on cwd).
Shows a "cwd is a worktree of this project" banner when applicable.

### `bin/scratch-project-create` (leaf)

Interactive project creation.
Takes an optional positional PATH (defaults to cwd).
Prompts via `gum input` for name and exclude patterns; detects git status automatically.

### `bin/scratch-project-edit` (leaf)

Interactive project editing.
Takes an optional positional NAME with the same resolution rules as `show`.
Prompts for each field via `gum input` / `gum choose`.

### `bin/scratch-project-delete` (leaf)

Interactive project deletion with `gum confirm` prompt.
Takes an optional positional NAME with the same resolution rules as `show`.

## Helper Scripts

### `helpers/setup`

Runtime dependency installer.
MUST be bash 3.2 compatible because its job is to install bash 5+.

Modes:
- (no args) - install all missing runtime deps via brew or apt-get
- `--check` - silent pass/fail gate; exits 0 if all deps present, 1 with warnings if not

Called by `bin/scratch` at startup to verify deps before dispatching.
Also the target of `scratch setup` and `scratch doctor --fix`.

### `helpers/run-tests`

Test runner.
Runs bats under `env -i` with a minimal allowlist (PATH, HOME, OSTYPE, TMPDIR, TERM) to prevent the user's shell profile from leaking into the test runner.

Detects GNU parallel and uses inter-file parallelism (`-j`) capped at 8 jobs.
Warns and falls back to serial if parallel is missing.

### `helpers/root-dispatcher`

The target of `bin/scratch`'s `exec` after the version and dependency checks pass.
Kept out of `bin/` so `dispatch:list "scratch"` does not accidentally see it as a child.

It is structurally identical to any other parent command: try `dispatch:try "scratch" "$@"`, and on fallthrough print `dispatch:usage` and exit.
Has no behavior of its own.

### `helpers/embed`

Embedding generator wrapper.
Sets `CXX` with `-Wno-error=missing-template-arg-list-after-template-kw` to work around Apple clang 17+ promoting that warning to an error during EXLA NIF compilation.
Execs `libexec/embed.exs` with the given arguments.

## Internal Executables

### `libexec/embed.exs`

Elixir embedding generator.
Uses Bumblebee + EXLA with `sentence-transformers/all-MiniLM-L12-v2` to produce 384-dimensional vectors.

Input: file path or `-` for stdin.
Output: JSON array of floats on stdout.
Logging: Elixir/EXLA noise routed to stderr.

Model cache: `~/.config/scratch/models/` via `BUMBLEBEE_CACHE_DIR`.

EXLA pinned to `0.9.2` (avoid 0.10.0 duplicate symbol linker bug).
Requires bash wrapper for the clang workaround (see `helpers/embed`).

## Test Files

| File | Purpose |
|---|---|
| `test/helpers.sh` | Test utilities: `is`, `diag`, `make_stub`, `prepend_stub_path` |
| `test/base.bats` | Tests for `lib/base.sh` |
| `test/termio.bats` | Tests for `lib/termio.sh` (if present) |
| `test/cmd.bats` | Tests for `lib/cmd.sh` |
| `test/dispatch.bats` | Tests for `lib/dispatch.sh` |
| `test/project.bats` | Tests for `lib/project.sh` |
| `test/scratch-doctor.bats` | Tests for `bin/scratch-doctor` |
| `test/lint.bats` | Self-reflection: shellcheck |
| `test/formatting.bats` | Self-reflection: shfmt drift |
| `test/permissions.bats` | Self-reflection: +x policy |
| `test/anti-slop.bats` | Self-reflection: no smart quotes or em dashes |
| `test/subcommand-contract.bats` | Self-reflection: subcommands honor --help |
