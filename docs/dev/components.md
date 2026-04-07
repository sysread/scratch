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

### `lib/venice.sh`

Foundation for the Venice API integration.
Depends on `base.sh`.
Requires `curl`, `jq`, and `bc` at source time.

Functions:
- `venice:api-key` - print the API key; tries `SCRATCH_VENICE_API_KEY` first, then `VENICE_API_KEY`; dies with a clear message if neither is set
- `venice:base-url` - print the hard-coded Venice API base URL
- `venice:config-dir` - print (and create) `~/.config/scratch/venice/`; resolves under `$HOME`, so tests running with isolated HOME get isolated config automatically
- `venice:curl METHOD PATH [BODY]` - authenticated request wrapper with automatic retry on transient errors; body via stdin to avoid argv limits; translates Venice-specific error codes (401/402/429/503/504) into user-targeted `die` messages

Private helpers:
- `_venice:_backoff-seconds ATTEMPT` - compute retry delay via a log10 curve (`ceil(2 * (1 + log10(attempt)))`); uses `bc -l` for the floating-point math

Retry behavior:
- Transient errors (429 rate-limited, 503 at capacity, 504 timeout) retry up to `SCRATCH_VENICE_MAX_ATTEMPTS` times (default 3).
- Each retry sleeps for a log10-scaled backoff and logs a warn to stderr with `(attempt N/max)` so long pauses have visible cause.
- Non-retryable errors (401, 402, 415, other 4xx) die immediately without retrying.
- The log10 curve: attempt 1 -> 2s, attempt 10 -> 4s, attempt 100 -> 6s, attempt 1000 -> 8s. Self-caps in practice because log grows so slowly.

Tunables (env vars):
- `SCRATCH_VENICE_MAX_ATTEMPTS` - max HTTP attempts before giving up. Set to 1 to disable retry entirely (useful in tests).

### `lib/model.sh`

Cached Venice model registry.
Depends on `base.sh` and `venice.sh`.
Requires `jq`.

Functions:
- `model:cache-path` - print the absolute path to the cache file
- `model:fetch` - pull `?type=all` from Venice, atomic write to the cache (tmp + mv)
- `model:list [TYPE]` - print sorted model ids, optionally filtered by top-level `type` field
- `model:get ID` - print the full JSON object for one model; dies if not found
- `model:exists ID` - silent predicate; returns 0 if the id is in the cache, 1 otherwise (this is an existence check, not capability validation - profile validation lives under `model:profile:validate`)
- `model:jq ID EXPR` - run an arbitrary jq expression rooted at one model's object

All read functions lazy-load the cache through the private `_model:ensure-cache` helper.
First call from a fresh install triggers `model:fetch` automatically.
There is no TTL; refresh the cache by calling `model:fetch` explicitly.

Profile functions (`model:profile:*`):
- `model:profile:data-path` - print the path to `data/models.json` (the profile data file shipped in the repo)
- `model:profile:list` - print all profile names (base + variants), sorted, one per line
- `model:profile:exists NAME` - silent predicate; returns 0 if NAME is defined as either a base or a variant
- `model:profile:resolve NAME` - print the fully-merged JSON for a profile, with variant overrides deep-merged onto the base via jq's `*` operator
- `model:profile:model NAME` - convenience: print just the resolved profile's `.model` field
- `model:profile:extras NAME` - print the JSON object shaped for `chat:completion`'s third argument (params flattened to top level, `venice_parameters` kept nested, omitted entirely if empty)
- `model:profile:validate NAME` - check that the profile is internally consistent: profile exists, the model id exists in the registry cache, and every requested param/venice_parameter is supported by the model's declared capabilities. Reports ALL capability failures at once via `warn` before returning 1, so the user can fix everything in one pass instead of running validate repeatedly.

Profiles live in `data/models.json` (tracked in the repo, not user-configurable). The file has two top-level groups:
- `base` - standalone profiles (smart, balanced, fast)
- `variants` - profiles that `extends` a base and add their own params/venice_parameters

Resolution does a recursive deep-merge so variant overrides combine with their base's params rather than replacing them. Variants extending other variants works transitively (resolve calls itself recursively); cycles are not detected and would stack overflow, so don't write them.

The capability mapping for validation lives in two private associative arrays at the top of the profile section: `_MODEL_PARAM_CAPABILITIES` (top-level params -> required capabilities) and `_MODEL_VENICE_PARAM_CAPABILITIES` (venice_parameters -> required capabilities). Adding a new mapping teaches validate about a new parameter without changing the validation logic.

### `lib/chat.sh`

Venice chat completions wrapper.
Depends on `base.sh`, `venice.sh`, and `tool.sh`.
Requires `jq`.

Functions:
- `chat:completion MODEL MESSAGES_JSON [EXTRA_JSON]` - POST `/chat/completions` with a shallow-merged request body; returns the full response on stdout
- `chat:extract-content` - stdin-only; reads a completion response and prints `.choices[0].message.content` with `// ""` fallback
- `chat:complete-with-tools MODEL MESSAGES_JSON TOOL_NAMES_JSON [EXTRA_JSON]` - the recursion driver. Wraps `chat:completion` in a loop that executes any tool_calls the model returns (via `tool:invoke-parallel`), appends the assistant message and tool result messages to the conversation, and recurses until the model returns a plain text response. No max-rounds cap by design. Defensive `.function.arguments | (fromjson? // {})` parsing so a malformed argument string falls back to `{}` instead of crashing the recursion. Empty `TOOL_NAMES_JSON` dies (use `chat:completion` directly for the no-tools case).

The library deliberately has no message builder API - callers construct messages arrays themselves and pass them as JSON.
Extras (`temperature`, `venice_parameters`, `tools`, `response_format`, etc.) go in the third argument as a JSON object that gets merged shallowly into the request body. Note that `chat:complete-with-tools` always overrides `tools` with what it built from `TOOL_NAMES_JSON`.

### `lib/tool.sh`

Tool calling infrastructure.
Depends on `base.sh`, `tempfiles.sh`, `project.sh`.
Requires `jq`.

A "tool" is a self-contained directory under `tools/<name>/` with three required files:
- `spec.json` - OpenAI function-calling JSON spec (the inner `{name, description, parameters}` object)
- `main` - executable, any language. Receives args via `SCRATCH_TOOL_ARGS_JSON` env var. Exit 0 + stdout = success result; non-zero + stderr = failure result. Strict separation, no merging.
- `is-available` - bash script that doubles as runtime gate AND dependency manifest. Sources `lib/base.sh` and calls `has-commands` for any external programs the tool needs. The doctor scanner picks up these declarations and attributes them to `tool:<name>`.

Functions:
- `tool:tools-dir` - print the tools directory (honors `SCRATCH_TOOLS_DIR` for tests)
- `tool:list` - sorted tool names, one per line
- `tool:exists NAME` - silent predicate
- `tool:dir NAME` - absolute path; dies if missing
- `tool:spec NAME` - raw spec.json contents
- `tool:specs-json [NAMES...]` - JSON array of OpenAI-wire-format wrapped specs `[{type:"function", function:<spec>}]`. Filters out unavailable tools unless `SCRATCH_TOOL_SKIP_AVAILABILITY=1`.
- `tool:available NAME` - runs `is-available` with the env contract; captures stderr in `_TOOL_AVAILABILITY_ERR`
- `tool:invoke NAME ARGS_JSON` - synchronously execute `main` with the env contract. Captures stdout into `_TOOL_INVOKE_STDOUT` and stderr into `_TOOL_INVOKE_STDERR` via tempfile redirects (NOT process substitution, to preserve exit codes). Returns the tool's exit code. Returns 127 if `is-available` fails first.
- `tool:invoke-parallel CALLS_JSON` - parallel execution via background jobs + wait. `CALLS_JSON` is a JSON array of `{id, name, args}` matching the OpenAI tool_calls shape. Forks one bg job per call, captures each tool's streams to numbered temp files in a `tmp:make`-allocated workdir (in the parent shell, NOT in subshells, because `tmp:make`'s registry lives in parent process memory). Results assemble in input order regardless of completion order. Failures encode as `ok:false`; silent failures get a synthesized `ERROR: tool '<name>' exited with status <code>` fallback.

Environment contract for tool main scripts:
- `SCRATCH_TOOL_ARGS_JSON` - LLM args as JSON object
- `SCRATCH_TOOL_DIR` - the tool's own directory (for sibling files)
- `SCRATCH_HOME` - scratch repo root (so bash tools can `source "$SCRATCH_HOME/lib/..."`)
- `SCRATCH_PROJECT` and `SCRATCH_PROJECT_ROOT` - only set if `project:detect` succeeds; tools should test `[[ -n ${SCRATCH_PROJECT:-} ]]`

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

See `test/01-cmd.bats` for examples of every function.

## Subcommands

### `bin/scratch-doctor`

Environment health check.
Intentionally independent of `cmd.sh`, `tui.sh`, and `gum` - it must work when dependencies are broken.
Uses raw ANSI `printf` with TTY detection for output.

Checks:
- bash version (5+)
- All commands declared via `has-commands` in `bin/`, `lib/`, `helpers/`, and `tools/<name>/is-available`
- All env vars declared via `require-env-vars` in the same scan set
- Dev tools from `.mise.toml` + GNU parallel (with `--dev`)

Scan attribution:
- `bin/scratch-<verb>` files attribute to `<verb>`
- `lib/*.sh` files attribute to the synthetic label `lib` (since library deps apply transitively to many consumers)
- `helpers/<name>` files attribute to `<name>` (e.g., `embed` for `helpers/embed`, which declares `has-commands elixir`)
- `tools/<name>/is-available` files attribute to `tool:<name>` (e.g., `tool:notify` for `tools/notify/is-available`). The `tool:` prefix disambiguates tool deps from bin/lib/helper deps in the doctor output.

The four scan targets share a single `_scan-deps-in` helper - one line per target in `scan-all-deps`. Adding a fifth scan target later is a one-line addition.

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

Unit test runner.
Runs bats under `env -i` with a minimal allowlist (PATH, HOME, OSTYPE, TMPDIR, TERM) to prevent the user's shell profile from leaking into the test runner.

Isolation guarantees:
- `HOME` is overridden to a fresh `mktemp -d` directory, cleaned up on exit via trap.
- A curl stub is installed on PATH that fails loudly if any test tries to hit the network without mocking it. Per-test stubs via `make_stub` override transparently.

Test discovery is a non-recursive `test/*.bats` glob, so integration tests under `test/integration/` do not run by default.

Detects GNU parallel and uses inter-file parallelism (`-j`) capped at 8 jobs.
Warns and falls back to serial if parallel is missing.

### `helpers/run-integration-tests`

Integration test runner for tests that make real Venice API calls.

Key differences from `run-tests`:
- HOME is still isolated to a tmpdir (prevents polluting the user's real venice model cache).
- NO curl network guard.
- Forwards `SCRATCH_VENICE_API_KEY` and `VENICE_API_KEY` from the caller's environment.
- Serial only (no parallelism against a paid, rate-limited API).
- Runs only `test/integration/*.bats`.

Individual tests `skip` cleanly if no API key is set, so contributors without one still get a green run.
Never run automatically in CI.
Opt in via `mise run test:integration` or by calling the script directly.

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

## Tools

LLM tool calling lives under `tools/<name>/`. Each tool is a self-contained directory with three required files (see the `lib/tool.sh` entry above for the contract). Tools are reserved for LLM use - this is not a general scripts directory.

### `tools/notify/`

The first concrete tool. Wraps `tui:info` / `tui:warn` / `tui:error` so the LLM can communicate progress, status, warnings, or errors back to the user during long-running work. The notification renders in real time in the user's terminal; the tool's stdout response is a confirmation the LLM sees.

- `spec.json` - takes `level` (enum: `info|warning|error`) and `message` (string)
- `main` - bash; sources `lib/base.sh`, `lib/termio.sh`, `lib/tui.sh` from `$SCRATCH_HOME`; parses `$SCRATCH_TOOL_ARGS_JSON`; dispatches on level
- `is-available` - bash; sources `lib/base.sh`; calls `has-commands gum jq`. Doctor scanner picks up `gum` and `jq` under `tool:notify`.

This is the simplest possible scratch tool. It exists to (a) exercise the full tool calling pipeline end to end and (b) give LLMs a way to talk to the user during multi-step work without requiring response streaming.

## Test Files

Test files use 2-digit numerical prefixes (CPAN convention) so they run in dependency order: lib tests first (00-06), bin tests next (10+), self-reflection tests last (90+). Gaps between groups leave room to wedge in new tests without renumbering.

| File | Purpose |
|---|---|
| `test/helpers.sh` | Test utilities: `is`, `diag`, `make_stub`, `prepend_stub_path` |
| `test/00-base.bats` | Tests for `lib/base.sh` |
| `test/01-cmd.bats` | Tests for `lib/cmd.sh` |
| `test/02-dispatch.bats` | Tests for `lib/dispatch.sh` |
| `test/03-project.bats` | Tests for `lib/project.sh` |
| `test/04-venice.bats` | Tests for `lib/venice.sh` (stubs curl binary) |
| `test/05-model.bats` | Tests for `lib/model.sh` (registry + profiles; overrides `venice:curl`) |
| `test/06-chat.bats` | Tests for `lib/chat.sh` including `chat:complete-with-tools` recursion (multi-response capture queue, stubbed tool layer) |
| `test/07-tool.bats` | Tests for `lib/tool.sh` (sync half + parallel) using fake tool fixtures under `SCRATCH_TOOLS_DIR` |
| `test/10-scratch-doctor.bats` | Tests for `bin/scratch-doctor` |
| `test/90-lint.bats` | Self-reflection: shellcheck |
| `test/91-formatting.bats` | Self-reflection: shfmt drift |
| `test/92-permissions.bats` | Self-reflection: +x policy |
| `test/93-anti-slop.bats` | Self-reflection: unicode + AI attribution in unpushed commits |
| `test/94-subcommand-contract.bats` | Self-reflection: subcommands honor --help |
| `test/95-tool-contract.bats` | Self-reflection: every tool dir under `tools/` follows the structural contract (spec.json shape, name match, +x bits, is-available sources base + calls has-commands) |
| `test/integration/00-venice.bats` | Opt-in integration tests against the real Venice API |
