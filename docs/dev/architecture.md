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

For subcommand-specific help, pass `--help` directly: `scratch search --help`.
`scratch help` is a standalone subcommand (guide browser + self-help agent), not a dispatch shortcut.

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
  scratch-intuit           leaf - debug invocation of agents/intuition
  scratch-index            leaf - build/update project file index
  scratch-search           leaf - semantic search over project index
  scratch-file-info        leaf - show index status/summary for a file

lib/          sourced libraries (not executable)
  base.sh         warn, die, has-commands, require-env-vars
  termio.sh       io:is-tty, io:sedl, io:strip-ansi, etc.
  tui.sh          tui:log, tui:format, tui:spin, tui:choose (gum wrappers)
  tempfiles.sh    tmp:make, tmp:cleanup (trap-based temp file registry)
  prompt.sh       prompt:load, prompt:render (loads data/prompts/<feature>/*.md)
  project.sh      project:save, project:load, project:detect (worktree-aware)
  cmd.sh          cmd:define, cmd:parse, cmd:get (declarative command framework)
  dispatch.sh     dispatch:try, dispatch:usage (parameterized subcommand dispatch)
  venice.sh       venice:api-key, venice:curl (Venice API primitives)
  model.sh        model:fetch, model:list, model:exists, model:jq (registry) +
                  model:profile:* (profile system, sourced from data/models.json)
  chat.sh         chat:completion, chat:extract-content, chat:complete-with-tools
  tool.sh         tool:list, tool:invoke, tool:invoke-parallel (tool calling)
  accumulator.sh  accumulate:run, accumulate:run-profile (chunk + reduce + finalize
                  for inputs that exceed a model's context window)
  workers.sh      workers:cpu-count, workers:run-parallel (FIFO-semaphore worker
                  pool primitive used by shellcheck_parallel and tool:invoke-parallel)
  agent.sh        agent:list, agent:run, agent:simple-completion (the agent layer;
                  agents are run scripts under agents/<name>/, not config bundles)
  db.sh           db:exec, db:query, db:migrate (SQLite primitives; all DB
                  access goes through this layer)
  index.sh        index:record, index:lookup, index:list (per-project index CRUD)
  search.sh       search:embed, search:query, search:is-stale (search pipeline)

libexec/      internal non-bash executables
  embed.exs       Elixir embedding generator (called by helpers/embed); two modes:
                  single-input (backward compat) and JSONL pool via Task.async_stream
  cosine-rank.awk cosine similarity ranking (used by lib/search.sh)

data/         static config data shipped in the repo (not user settings)
  models.json     model profile definitions (smart/balanced/fast/long-context
                  bases + coding/web variants), read by lib/model.sh's
                  model:profile:* functions
  models.md       schema reference for models.json (lives next to the data
                  so contributors find it when adding profiles)
  prompts/        LLM prompt assets, organized as <feature>/<name>.md
    README.md     storage convention, placeholder syntax, lib/prompt.sh API
    accumulator/  system, finalize, line-numbers prompts for lib/accumulator.sh
    echo/         system prompt for agents/echo
    intuition/    perception, synthesis, drive-base, drives/* for agents/intuition
    summary/      accumulate + structure prompts for agents/summary
  migrations/     forward-only SQL migration files
    index/        schema for the per-project index database

tools/        LLM tool calling. Each subdirectory is a self-contained tool:
              <name>/spec.json     OpenAI function spec (the inner function obj)
              <name>/main          executable, any language
              <name>/is-available  bash; runtime gate AND dep manifest
  notify/         proxies tui:info/warn/error so the LLM can talk to the user

agents/       Reusable LLM workflows. Each subdirectory is a self-contained agent:
              <name>/spec.json     metadata: name, description
              <name>/run           executable, any language; reads stdin, prints stdout
              <name>/is-available  bash; runtime gate AND dep manifest (same contract
                                   as tools, including the policy-gate pattern - an
                                   agent can refuse to be available outside edit mode)
  echo/           single-shot reference; built on agent:simple-completion
  intuition/      complex multi-phase reference (perception + parallel drives + synthesis)
  summary/        file summarizer for indexing (accumulator + structured output)

toolboxes/    Named bundles of tool names with their own is-available gate.
              <name>/tools.json    {"description": "...", "tools": [...]}
              <name>/is-available  bash; runtime policy gate
  interactive/    notify and similar; gated on stderr being a TTY
  read-only/      tools safe to run anywhere; always available
  editing/        tools that mutate state; gated on SCRATCH_EDIT_MODE; empty for now

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
  06-chat.bats                 tests for lib/chat.sh (incl. complete-with-tools)
  07-tool.bats                 tests for lib/tool.sh (sync + parallel)
  08-prompt.bats               tests for lib/prompt.sh (load + render)
  09-accumulator.bats          tests for lib/accumulator.sh (text + chat layers)
  10-scratch-doctor.bats       tests for bin/scratch-doctor (fake SCRATCH_HOME)
  11-tui.bats                  tests for lib/tui.sh (tui:log dispatch)
  12-tempfiles.bats            tests for lib/tempfiles.sh (tmp:make + tmp:cleanup)
  13-workers.bats              tests for lib/workers.sh (worker pool primitive)
  14-agent.bats                tests for lib/agent.sh (data access + run + simple-completion)
  90-lint.bats                 self-reflection: shellcheck
  91-formatting.bats           self-reflection: shfmt drift
  92-permissions.bats          self-reflection: +x policy
  93-anti-slop.bats            self-reflection: unicode + AI attribution
  94-subcommand-contract.bats  self-reflection: subcommands honor --help
  95-tool-contract.bats        self-reflection: every tool dir follows the contract
  96-agent-contract.bats       self-reflection: every agent dir follows the contract
  97-toolbox-contract.bats     self-reflection: every toolbox dir follows the contract

test/integration/   bats tests that hit the REAL venice API (opt-in only)
  00-venice.bats         end-to-end smoke tests for venice + model + chat
  01-accumulator.bats    end-to-end accumulator against real models
  02-agent.bats          end-to-end echo + intuition agents against real models

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
  +-- tool.sh        (depends on base + tempfiles + project, requires jq)
  |
  +-- venice.sh      (depends on base, requires curl + jq + bc)
        |
        +-- model.sh (depends on base + venice, requires jq)
        |
        +-- chat.sh  (depends on base + venice + tool, requires jq)
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
Venice's documented error codes (401, 402, 429, 500, 503, 504) get translated into user-targeted `die` messages: "insufficient credits, top up at...", "rate limited, wait and retry", etc.
A 400 with `.error.code == "context_length_exceeded"` is the one exception that does NOT die: it returns exit code 9 with the body on stderr so the accumulator can catch it and drive its reactive shave-and-retry backoff.

Transient errors (429, 500, 503, 504) are automatically retried up to `SCRATCH_VENICE_MAX_ATTEMPTS` times (default 3) with a log10 backoff between attempts.
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

## Tool Calling Pipeline (tool.sh + chat:complete-with-tools)

Tool calling lets the LLM execute things in the user's environment (read files, run commands, send notifications, etc.) instead of just producing text. The architecture has three layers, each with one job.

### Layer 1: tools/ (the tool definitions)

Each tool is a self-contained directory under `tools/<name>/` with three required files - the format borrowed from fnord's "frob" system, with one scratch addition.

`spec.json` - the OpenAI function calling spec. Contains `name`, `description`, and `parameters` (a JSON Schema object). The LLM uses this to decide when and how to invoke the tool. The directory basename must match `.name` (enforced by `test/95-tool-contract.bats`).

`main` - the executable. Any language. Reads its arguments from `SCRATCH_TOOL_ARGS_JSON` (an env var holding the LLM's parsed argument object). Writes its result to stdout on success or stderr on failure. The exit code determines which stream becomes the result content sent back to the LLM:

- exit 0 -> stdout content goes to the LLM
- non-zero -> stderr content goes to the LLM

This is **strict separation** with no merging - different from fnord which uses `stderr_to_stdout: true`. Strict separation lets tools write progress notes to stderr without polluting the success result.

Tools also receive these env vars from the contract:

- `SCRATCH_TOOL_ARGS_JSON` - the LLM's args (always set; `{}` for no-arg tools)
- `SCRATCH_TOOL_DIR` - the tool's own directory (for fixtures or sub-scripts)
- `SCRATCH_HOME` - scratch repo root (so bash tools can `source "$SCRATCH_HOME/lib/..."`)
- `SCRATCH_PROJECT` and `SCRATCH_PROJECT_ROOT` - only set if `project:detect` succeeds

`is-available` - bash, mandatory, scratch's addition to fnord's frob format. Two purposes in one file:

1. **Runtime gate:** Sources `lib/base.sh` and calls `has-commands` for any external programs the tool needs. If any are missing, the script dies with an install hint via the standard `has-commands` error path. Returns 0 if everything is present.

2. **Dependency manifest:** The doctor's textual scanner reads `is-available` looking for `has-commands` declarations, attributing them to `tool:<name>` (e.g. `gum (tool:notify)`). Same line does double duty: real runtime check AND scannable token. The contract test enforces both properties so no tool author can write a no-op gate.

### Layer 2: lib/tool.sh (the runtime)

`lib/tool.sh` provides discovery, schema reading, availability gating, and synchronous + parallel invocation. See the `lib/tool.sh` entry in `components.md` for the full API.

The tricky function is `tool:invoke-parallel`. It takes a JSON array of `{id, name, args}` calls and forks one background job per call. Each job writes captured stdout, stderr, and exit code to numbered temp files in a workdir allocated by the parent shell. After `wait`, the parent reassembles the results in **input order** (not wait order, which would be non-deterministic).

The workdir is allocated via `mktemp -d` in the parent shell, then registered with `tmp:track` so it's cleaned up on exit. **Critical:** `tmp:make` cannot be called from inside the bg jobs - the registry lives in parent process memory and subshell registrations are lost.

Failures are encoded as `ok:false` rather than dying, so a single broken tool doesn't kill the whole batch. Silent failures (non-zero exit + empty stderr) get a synthesized `ERROR: tool '<name>' exited with status <code>` content fallback so the model always has something actionable.

### Layer 3: chat:complete-with-tools (the recursion driver)

`chat:complete-with-tools MODEL MESSAGES_JSON TOOL_NAMES_JSON [EXTRA_JSON]` wraps `chat:completion` in a loop. Each iteration:

1. Calls `chat:completion` with the current messages and the tools array (built from `TOOL_NAMES_JSON` via `tool:specs-json`).
2. Checks the response for `.choices[0].message.tool_calls`.
3. If empty, returns the response (text content, recursion done).
4. If present, executes the calls via `tool:invoke-parallel`, appends the assistant message and one tool result message per call to the messages array, and continues to the next iteration.

There is **no max-rounds cap** by design. A runaway model burns API credit until Ctrl-C; in practice this hasn't been a problem.

The tool argument parsing is defensive: `.function.arguments` is a JSON string per the OpenAI spec, but malformed strings shouldn't crash the recursion. The driver uses `(fromjson? // {})` to fall back to an empty object on parse failure, so the tool sees a clean (if useless) `{}` arg shape and can fail with its own clear error message.

### Why this layered design

Each layer has exactly one job:

- **`tools/<name>/`** is *what* the tool does and *whether* it's available.
- **`lib/tool.sh`** is *how* tools are discovered, gated, and run.
- **`chat:complete-with-tools`** is *when* tools fire during a model conversation.

A future agent system can use any combination of these without coupling. An agent that uses tools without an LLM (e.g. cron-driven) would call `tool:invoke` directly. An agent that uses an LLM without tools would call `chat:completion` directly. An agent that uses both calls `chat:complete-with-tools`. The layers compose; you don't pay for what you don't use.

### Toolboxes: named bundles with policy gates

`toolboxes/<name>/` adds a layer above individual tools.
A toolbox is a named bundle of tool names with its own `is-available` gate, defined as:

```
toolboxes/<name>/
  tools.json     {"description": "...", "tools": ["a", "b"]}
  is-available   bash; runtime policy gate
```

An agent that wants "all the safe filesystem tools" references the bundle by name instead of enumerating tools.
The policy lives with the bundle: `toolboxes/read-only/is-available` decides whether read-only is on right now (almost always yes), `toolboxes/editing/is-available` decides whether editing is on (only when `SCRATCH_EDIT_MODE=1`), and so on.

`tool:box NAME` returns the bundle's full `tools.json` content on success or the same shape with `tools` replaced by `[]` on failure.
The empty fallback lets callers always do `... | jq -r '.tools[]'` without branching on the error case.
Failure also emits a tui:debug warning ONCE per process per unavailable toolbox via `_TOOLBOX_WARNED`, so a multi-phase agent that probes the same disabled box across rounds does not produce repeated noise.

Composition with the existing primitives is one line:

```bash
tool:specs-json $(tool:box read-only | jq -r '.tools[]')
```

The same tool can appear in multiple toolboxes (e.g. `notify` is in both `interactive/` and `read-only/`).
Toolboxes do not have ownership semantics over tools.

### Layer ownership for toolboxes

- **`toolboxes/<name>/`** is *which* tools are in the bundle and *whether* the bundle is available.
- **`tools/<name>/`** is still *what* an individual tool does and *whether* it specifically is available.
- **`tool:box NAME`** returns the resolved bundle (or the empty fallback).
- **`tool:specs-json`** is unchanged - it works on tool names regardless of where they came from.

The layers compose: an agent can ask for a toolbox, get a list of tool names, hand them to `tool:specs-json`, and the per-tool `is-available` gates still fire individually. A toolbox failing closed (`tools: []`) and a tool failing closed (filtered out by `tool:specs-json`) are independent failure modes that compose naturally.

## Accumulator Pattern (accumulator.sh + prompt.sh)

`lib/accumulator.sh` processes inputs that exceed a model's context window by chunking the input, running a chat completion round per chunk that builds up structured `accumulated_notes`, then a final cleanup pass that returns the user-facing answer.
The pattern is the standard solution for "this file does not fit": split, reduce, finalize.

The design borrows the shape from fnord's `AI.Accumulator` (Elixir) and adapts it to bash with three significant scratch additions: a structured-output contract for the buffer, per-profile fractional `chars_per_token`, and reactive backoff via `venice:curl` exit code 9.

### Three layers

1. **Pure text helpers** (`_accumulate:_token-count`, `_accumulate:_max-chars`, `_accumulate:_split`, `_accumulate:_inject-line-numbers`).
   Estimate token budgets via `chars / chars_per_token` through `bc -l`, pre-split inputs into numbered chunk files line-aware, and optionally inject `<line_number>:<hash>|<content>` prefixes for downstream edit tooling.
   No model awareness, no API calls.

2. **Chat-layer wrappers** (`_accumulate:_process-chunk`, `_accumulate:_finalize`, `_accumulate:_process-chunk-with-backoff`).
   Render the accumulator's system prompts via `prompt:render`, embed structured-output schemas as `response_format`, call `chat:completion`, and parse the structured response.
   The backoff wrapper catches `venice:curl` exit code 9 (context overflow) bubbling through `chat:completion` and drives a per-chunk shave-and-retry recursion.

3. **Public entry points** (`accumulate:run`, `accumulate:run-profile`).
   The reduce loop iterates pre-split chunks against the same `notes` buffer, then runs the finalize pass.
   `accumulate:run-profile` resolves a model profile, defaults `chars_per_token` from the profile (or 4.0), and merges the profile's params into `extras`.

### Structured-output contract

Both round and final responses use OpenAI-compatible `json_schema` with `strict: true`.
The round schema requires `current_chunk` (a one-sentence acknowledgement, audit-trail only) and `accumulated_notes` (the running state, fed back into the next round's input).
The final schema requires `result` (the user-facing answer).
Field names are deliberately verbose because the model has no shared context with scratch and short names would be ambiguous on first read.

Constraining the buffer via `response_format` is the key improvement over a free-form prose buffer: the model does not have to re-parse its own previous output, and the schema eliminates a whole class of "the model forgot the format" errors.

### Reactive backoff

Pre-split is conservative at 70% of `(max_context_tokens * chars_per_token)`, leaving headroom for the system prompt and the running buffer.
On context overflow, `venice:curl` returns exit code 9 (with `.error.code == "context_length_exceeded"` matched in `_venice:_is-context-overflow`).
`chat:completion` propagates the exit code through naturally because it is the last command in the function.
The accumulator's backoff wrapper catches exit code 9 and re-splits the failing chunk at progressively smaller fractions (0.6, 0.5, 0.4, 0.3) until the resulting sub-chunks fit or the floor is hit.

The fraction resets to the start fraction on the next outer chunk because the budget at any round depends on the buffer size at that round, not on a stable per-model property.

### Where prompts live

Prompts are flat markdown files under `data/prompts/<feature>/<name>.md`, loaded by `lib/prompt.sh`.
The accumulator's prompts live in `data/prompts/accumulator/`:
- `system.md` - per-round meta prompt with `{{user_prompt}}`, `{{question}}`, `{{notes}}` placeholders
- `finalize.md` - cleanup-pass meta prompt with the same placeholders
- `line-numbers.md` - additional system prompt section appended when line_numbers mode is enabled

Storing prompts as files instead of bash heredocs keeps them out of shell escaping rules, lets editors and the anti-slop scan treat them as the documents they are, and gives a clear graduation path for the much larger collection of prompts that future agents will need.

### Where this fits in the bigger picture

Accumulator sits one layer above `chat:completion` and one layer below user-facing subcommands and agents.
A subcommand that operates on a single file calls `accumulate:run-profile` directly with the file as input.
An agent that wants to summarize a large document before reasoning over it calls accumulator first, then passes the result to its own `chat:completion` calls.
The accumulator does not need to know whether it is being driven by a user, a subcommand, or an agent; the contract is the same.

## Agent Layer (agents/, lib/agent.sh)

An agent is a reusable LLM workflow.
Some agents are single-shot ("call one model with one system prompt and a tool list").
Some are multi-phase orchestrations (chunk a huge input, fan out N parallel sub-completions, synthesize, branch on a structured-output boolean, delegate to another agent).
The interface for both is the same: stdin in, stdout out, exit 0 on success.

The original design plan envisioned agents as JSON-config-plus-system.md bundles - a single `profile`, a single `system.md`, a single `tools` array.
That model was rejected after walking through how it would express an intuition-style multi-phase workflow.
A complex agent needs three different model profiles (one per phase), three different prompt sources (one per phase, plus a directory of sub-prompts for the fan-out), and the ability to compose with `accumulator`, `workers`, and other agents - none of which a static config can express.

### An agent is a directory with an executable run script

Same shape as `tools/`.

```
agents/<name>/
  spec.json     metadata: name, description
  run           executable, any language; reads stdin, prints stdout
  is-available  bash; runtime gate AND dependency manifest

data/prompts/<name>/    one or more prompt files loaded via prompt:load
```

The `run` script IS the agent.
A simple agent is ~5 lines wrapping `agent:simple-completion`.
A complex agent (like `agents/intuition/`) is ~120 lines that uses `accumulator`/`workers`/`chat`/`prompt`/`model`/`tui` directly and picks model profiles per phase.

### Environment contract for run scripts

- **stdin** = the user input
- **stdout** = the final response (plain text, whatever shape the agent wants)
- **stderr** = logs / progress
- `SCRATCH_AGENT_DIR` - the agent's own directory (for sibling files)
- `SCRATCH_HOME` - repo root (so the script can `source "$SCRATCH_HOME/lib/..."`)
- `SCRATCH_PROJECT` and `SCRATCH_PROJECT_ROOT` - only set if `project:detect` succeeds
- `SCRATCH_AGENT_DEPTH` - current recursion depth, incremented before fork; dies past `SCRATCH_AGENT_MAX_DEPTH` (default 8)

### lib/agent.sh is thin

```
agent:agents-dir              honors SCRATCH_AGENTS_DIR for tests
agent:list                    sorted agent names
agent:exists NAME             silent predicate
agent:dir NAME                absolute path
agent:spec NAME               raw spec.json
agent:available NAME          runs is-available, captures stderr
agent:run NAME                exec run with the env contract; pipes stdin through
agent:simple-completion       common-case helper for single-shot agents
```

There is no `agent:show`, `agent:profile`, `agent:tools`, or `agent:run-with-messages` - those were properties of the JSON-config model and have no meaning when the agent is code.

### is-available as policy gate

The same double-duty contract tools use: real runtime gate AND scannable dep manifest.
Agents can refuse to be available outside specific conditions: `SCRATCH_EDIT_MODE=1` set, cwd inside a known project, `gh` configured with a remote, etc.
The `is-available` script returns non-zero when any precondition fails; the doctor reports the failed dep with `agent:<name>` attribution; `agent:run` refuses to invoke an unavailable agent.

This is more than a dependency check.
It is policy.
A `code-editor` agent might require edit mode to be active.
A `pr-summarizer` might require a configured `gh` remote.
The pattern keeps the runtime gate and the doctor scan in one place so they can never disagree.

### The intuition reference agent

`agents/intuition/` is the complex reference: a 3-phase workflow that exercises every primitive in the lib stack.

1. **Perception** - read transcript on stdin, run a single chat completion to summarize the situation.
2. **Drive reactions (parallel)** - fan out 4 chat completions via `workers:run-parallel`, one per drive prompt (curiosity, skepticism, pragmatism, stewardship). Workers index into parent-shell arrays for their task data and write to per-index files in a workdir tracked via `tmp:track`.
3. **Synthesis** - concatenate the reactions and run a single chat completion that synthesizes them into a coherent first-person directive.

All three phases use the same `fast` profile with `venice_parameters.disable_thinking` enabled.
The value of intuition comes from running multiple lenses in parallel, not from any one phase being a deep thinker.
End-to-end ~10 seconds against the real API.
Adapted from fnord's `AI.Agent.Intuition` (Elixir, 370 lines, 10 drives) - this bash version is structurally identical but smaller for cost reasons.

The companion subcommand `bin/scratch-intuit` is the operator-facing entry point: `scratch intuit "what should I work on next?"`.

### Sub-agent composition

An agent's run script can call `agent:run other-name` (or invoke `bin/scratch agent run other-name` once that lands).
`SCRATCH_AGENT_DEPTH` increments per nested call; the cap fires before the fork so a runaway sub-agent chain never burns more than 8 levels of API budget.
Breadth (an agent that fans out to 10 sub-agents) is the agent author's problem, not the framework's.

### Where this fits in the bigger picture

The agent layer sits above `chat:complete-with-tools`, `accumulator`, `workers`, and `tool` - it composes with all of them but does not replace any.
A subcommand can still call `chat:completion` directly when an agent would be overkill.
A future "dispatch agent" that picks an agent based on intent calls `agent:run` recursively.
A future agent CLI surface (`scratch agent run <name>`) is a thin shell over `agent:run`.

The layers compose; you only pay for what you use.

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

The six scan sets have different attribution labels:
- `bin/scratch-<verb>` declarations attribute to the verb name
- `lib/*.sh` declarations attribute to the synthetic label `lib` (library deps apply transitively to many commands)
- `helpers/<name>` declarations attribute to the helper's basename (e.g., `helpers/embed` -> `embed`)
- `tools/<name>/is-available` declarations attribute to `tool:<name>` (e.g., `tool:notify`); the `tool:` prefix disambiguates tool deps from bin/lib/helper deps in the doctor output
- `agents/<name>/is-available` declarations attribute to `agent:<name>` (e.g., `agent:intuition`); same prefix-disambiguation rationale as tools
- `toolboxes/<name>/is-available` declarations attribute to `toolbox:<name>`; most toolboxes are pure policy gates with no binary deps of their own, so this scan target usually finds nothing in practice

All six scan loops use a single `_scan-deps-in` helper - one line per target in `scan-all-deps`.
The same binary may show up under multiple labels: `jq` reports as `(lib tool:notify agent:echo agent:intuition)`, surfacing the full set of consumers in one row.

When you add a new tool to scratch:
1. If it goes in a library, declare it in that library's source-time `has-commands` line.
2. If it's specific to one subcommand, declare it at the top of that subcommand's script.
3. If it's specific to one helper, declare it at the top of that helper.
4. If it's specific to an LLM tool, declare it in that tool's `is-available` script.
5. If it's specific to an agent, declare it in that agent's `is-available` script.
6. If it's specific to a toolbox (rare; toolboxes are usually pure policy), declare it in that toolbox's `is-available` script.
7. If it's a runtime dep that `scratch setup` should install, also add it to `helpers/setup`'s `RUNTIME_DEPS` list.

## File Indexing and Semantic Search

The indexing system maintains per-project summaries and embeddings so that `scratch search -q "how does auth work"` returns the most relevant files instantly.

**Storage**: One SQLite database per project at `~/.config/scratch/projects/<name>/index.db`. Forward-only migrations from `data/migrations/index/`. The `entries` table uses a `(type, identifier)` composite key so the same schema supports files, commits, conversations, and future index types.

**Three-phase indexing pipeline** (`scratch index`):

1. **Diff** — walk filesystem (via `git ls-files` or `find`), compare SHA-256 hashes against the index, classify files as new/changed/current. Remove orphaned entries.
2. **Summarize** — parallel workers run the summary agent against each file needing work. The summary agent uses `accumulate:run-profile` for large files, then a fast structuring pass to produce `{summary, questions}` JSON. Summaries are upserted into SQLite with `embedding = NULL`.
3. **Embed** — query SQLite for entries with NULL embeddings, pipe through `helpers/embed -n N` (JSONL pool mode), update entries with embeddings.

SQLite is the coordination point between phases. This decouples summarization (API-bound) from embedding (CPU-bound) and allows re-embedding without re-summarizing.

**Search** (`scratch search`): embeds the query via `helpers/embed`, dumps all indexed embeddings, pipes through `libexec/cosine-rank.awk` for cosine similarity ranking. The awk script handles the full ranking in a single process (~27ms for typical project sizes).

**Embedding pipeline**: `libexec/embed.exs` has two modes — single-input (backward compatible) and JSONL pool mode via `Task.async_stream`. Pool mode loads the model once and processes a stream of inputs with bounded concurrency, dropping per-item cost from ~2.3s to ~50-100ms.

## Self-Reflection Tests

Several bats files exist solely to enforce structural conventions:

- `90-lint.bats` - shellcheck on bin/, helpers/, lib/, test/
- `91-formatting.bats` - fails if shfmt would change any tracked file
- `92-permissions.bats` - enforces +x on bin/helpers/tools, -x on lib/libexec/data
- `93-anti-slop.bats` - fails on smart quotes, em dashes, or AI attribution in unpushed commits
- `94-subcommand-contract.bats` - verifies every subcommand honors `--help` with exit 0
- `95-tool-contract.bats` - verifies every tool dir under tools/ has spec.json + main + is-available with the correct shape, and is-available sources base.sh + calls has-commands
- `96-agent-contract.bats` - mirror of `95` for agents/<name>/ (spec.json + run + is-available, same is-available double-duty contract)
- `97-toolbox-contract.bats` - mirror of `95`/`96` for toolboxes/<name>/ (tools.json + is-available); additionally cross-references that every tool name in tools.json resolves to an existing tool

These tests catch drift that code review might miss.
They run under the same `env -i` harness as functional tests via `helpers/run-tests`.
