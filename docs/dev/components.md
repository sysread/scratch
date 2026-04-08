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
- `tui:log LEVEL [ARGS...]` - structured log via `gum log`. Dispatch is purely arg-driven: with args, log them directly (first arg is the message, the rest are key/value structured fields); with no args, read stdin line by line and log each line at LEVEL. Output is unconditionally on stderr per the conventions doc.
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
- `tmp:make VAR TEMPLATE [MKTEMP_ARGS...]` - create a temp file via `mktemp`, register it, assign the path to nameref VAR (NOT via `$(...)` - that would lose the registration in the subshell). TEMPLATE must be an absolute path; relative templates are rejected at the guard so a misuse cannot pollute the cwd (which would be the source tree if the caller is running from inside one).
- `tmp:track PATH` - register an existing path (a file OR directory created by other means, e.g. `mktemp -d`) for cleanup. `tmp:cleanup` uses `rm -rf` so directories work too.
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
- `venice:curl METHOD PATH [BODY]` - authenticated request wrapper with automatic retry on transient errors; body via stdin to avoid argv limits; dumps response headers via `curl -D` so the retry path can read Venice's rate-limit headers; translates Venice-specific error codes (401/402/429/500/503/504) into user-targeted `die` messages

Private helpers:
- `_venice:_backoff-seconds ATTEMPT` - compute retry delay via a log10 curve (`ceil(2 * (1 + log10(attempt)))`); uses `bc -l` for the floating-point math
- `_venice:_reset-wait HEADERS_FILE` - parse `x-ratelimit-reset-requests` (a unix timestamp) from a curl header dump and return seconds-until-reset, capped at `_VENICE_MAX_RESET_WAIT` (60s); empty when the header is missing, malformed, or stale
- `_venice:_is-context-overflow BODY` - return 0 if BODY matches Venice's `context_length_exceeded` envelope (exact match on `.error.code`); used by the 400 dispatch to translate that single shape into exit code 9 instead of dying

Special exit code 9 (context overflow):
A 400 whose body has `.error.code == "context_length_exceeded"` is not a death-worthy error from the caller's perspective - the accumulator wants to know about it so it can shave the chunk and retry. `venice:curl` returns exit code 9 with the body on stderr in that case. All other 400s still die immediately. The accumulator's `_accumulate:_process-chunk-with-backoff` is the primary consumer.

Retry behavior:
- Transient errors (429 rate-limited, 500 server error, 503 at capacity, 504 timeout) retry up to `SCRATCH_VENICE_MAX_ATTEMPTS` times (default 3). 429/500/503 are documented retryable codes for Venice; 504 is included defensively.
- For 429, the wait honors Venice's `x-ratelimit-reset-requests` header when present (capped at 60s); otherwise, and for the other transient codes, it falls back to the log10 backoff curve. This avoids the trap where our short backoff guarantees a second 429.
- Each retry logs a warn to stderr with `(attempt N/max)` so long pauses have visible cause.
- Non-retryable errors (401, 402, 415, other 4xx) die immediately without retrying.
- The log10 curve: attempt 1 -> 2s, attempt 10 -> 4s, attempt 100 -> 6s, attempt 1000 -> 8s. Self-caps in practice because log grows so slowly.
- A small uniform jitter (0..1 second with the default base) is added on top to break herd alignment when N parallel completions hit a 429 simultaneously. Disable for deterministic tests via `SCRATCH_VENICE_DISABLE_JITTER=1`.

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
- `base` - standalone profiles (smart, balanced, fast, long-context)
- `variants` - profiles that `extends` a base and add their own params/venice_parameters

Resolution does a recursive deep-merge so variant overrides combine with their base's params rather than replacing them. Variants extending other variants works transitively (resolve calls itself recursively); cycles are not detected and would stack overflow, so don't write them.

Profiles may also carry an optional top-level `chars_per_token` field (float, default 4.0 when absent). This is tooling metadata used by `lib/accumulator.sh` to estimate request sizes for chunking; it never reaches the Venice API and is not validated by `model:profile:validate` (which only walks `params` and `venice_parameters`). Different Venice models use different tokenizers, so the divisor varies; the embedding model runs around 3.0 chars/token and the default for general text is 4.0. The `long-context` base profile points at `qwen-3-6-plus` (1M token context) and is the accumulator's default.

See `data/models.md` for the full schema reference (top-level structure, profile fields, resolution semantics, validation rules, the `chars_per_token` rationale, and the "adding a new profile" workflow). It lives next to the data file so contributors find it when adding profiles.

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

### `lib/prompt.sh`

Prompt asset loader.
Depends on `base.sh`.
Requires `sed`.

Functions:
- `prompt:dir` - print the directory under which prompt files are resolved. Honors `SCRATCH_PROMPTS_DIR` for tests; otherwise resolves to `data/prompts/` next to `lib/`.
- `prompt:load NAME` - print the contents of `<prompts dir>/<NAME>.md`. NAME may contain slashes (e.g. `accumulator/system`). Dies with the resolved path if missing.
- `prompt:render NAME [VAR=VALUE ...]` - like `prompt:load` but additionally substitutes `{{var}}` placeholders with the supplied values via `sed`. Substitution is literal: no nesting, no escaping, unsupplied placeholders are left as-is so missing variables are visible during testing rather than silently dropped. Values containing `/`, `&`, `|`, and `\` are handled correctly via a private `_prompt:_sed-escape` helper.

Storing prompts as flat files instead of bash heredocs keeps them out of shell escaping rules and lets editors and the anti-slop scan treat them as the documents they are.
See `data/prompts/README.md` for the per-feature subdir convention and `data/prompts/accumulator/` for the first concrete consumer.

### `lib/accumulator.sh`

Accumulator-completion driver for inputs that exceed a model's context window.
Depends on `base.sh`, `tempfiles.sh`, `prompt.sh`, `chat.sh`, `model.sh`, `tui.sh`.
Requires `bc`, `awk`, `shasum`, `jq` at source time.

Public functions:
- `accumulate:run MODEL PROMPT INPUT [OPTIONS_JSON]` - chunk INPUT according to MODEL's context window, run a chat completion round per chunk that builds up structured `accumulated_notes`, then a final cleanup pass that returns the user-facing answer on stdout.
- `accumulate:run-profile PROFILE PROMPT INPUT [OPTIONS_JSON]` - convenience wrapper. Resolves PROFILE via `model:profile:resolve`, defaults `chars_per_token` from the profile (or 4.0), merges the profile's params/venice_parameters into `extras`, then forwards to `accumulate:run`. Caller-supplied options take precedence.

Private helpers:
- `_accumulate:_token-count TEXT_OR_FILE CHARS_PER_TOKEN` - approximate tokens via `chars / chars_per_token`, ceiling, through `bc -l`. Auto-detects whether the first arg is a literal string or a file path.
- `_accumulate:_max-chars MAX_TOKENS CHARS_PER_TOKEN FRACTION` - integer character budget for a chunk; floor.
- `_accumulate:_split INPUT_FILE MAX_CHARS OUT_DIR` - line-aware pre-split into numbered files (`0001`, `0002`, ...). Lazily opens chunks (so empty input produces zero files), packs lines until adding another would overflow, gives oversized lines their own chunk untruncated, handles input that does not end in a newline.
- `_accumulate:_inject-line-numbers INPUT_FILE OUT_FILE` - prefix every line with `<n>:<8 hex hash>|<content>`. Hash is the first 8 chars of `shasum -a 256` over the original line content; stable across identical lines so downstream agents can verify line identity at edit time. Must run BEFORE split so chunk boundaries fall on numbered-line boundaries.
- `_accumulate:_build-round-system-prompt` / `_accumulate:_build-final-system-prompt` - render `data/prompts/accumulator/system.md` and `finalize.md` via `prompt:render`. The line-numbers section is appended to the round system prompt when line_numbers mode is enabled.
- `_accumulate:_merge-extras EXTRAS SCHEMA` - inject the structured-output schema into `extras.response_format`, overriding any caller-supplied response_format with a `tui:warn` (the accumulator's contract trumps the caller).
- `_accumulate:_process-chunk` - run one round, parse the response for `accumulated_notes`, return it on stdout. Passes through `chat:completion`'s exit code 9 (context overflow from `venice:curl`) to the backoff loop.
- `_accumulate:_finalize` - run the cleanup pass with the finalize schema, parse the response for `.result`, print it as plain text.
- `_accumulate:_process-chunk-with-backoff` - the per-chunk shave-10% recursion. On exit code 9, shaves the fraction by `backoff_step` and re-splits the failing chunk at the smaller budget; processes the resulting sub-chunks recursively. Walks the floor at `floor_fraction` and dies with a clear "too dense" message naming the failing chunk.

Structured-output schemas:
The accumulator embeds two JSON schemas as top-level constants (`_ACCUMULATOR_ROUND_SCHEMA` and `_ACCUMULATOR_FINAL_SCHEMA`). Both use OpenAI-compatible `json_schema` format with `strict: true`. The round schema requires `current_chunk` (one-sentence acknowledgement, for the operator's audit trail) and `accumulated_notes` (the running structured-or-prose state). The final schema requires `result` (the user-facing answer). Field names are deliberately verbose because the model has no shared context with scratch and short names would be ambiguous.

Reactive backoff:
Pre-split is conservative at 70% of `(max_context_tokens * chars_per_token)`. On context overflow (`venice:curl` exit code 9 surfacing through `chat:completion`), the failing chunk gets re-split at progressively smaller fractions (0.6, 0.5, 0.4, 0.3) until it fits or hits `floor_fraction`. The fraction resets to `start_fraction` on the next outer chunk because the budget at any round depends on the buffer size at that round, not on a stable per-model property. See `scratch/02-accumulator.md` (or its sub-plans) for the design rationale.

OPTIONS_JSON keys (all optional):
`question`, `extras`, `max_context`, `chars_per_token` (default 4.0), `line_numbers` (default false), `start_fraction` (default 0.7), `floor_fraction` (default 0.3), `backoff_step` (default 0.1).

Prompts live in `data/prompts/accumulator/`:
- `system.md` - per-round meta with `{{user_prompt}}`, `{{question}}`, `{{notes}}` placeholders
- `finalize.md` - cleanup-pass meta with the same placeholders
- `line-numbers.md` - additional system prompt section appended when line_numbers mode is enabled

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
- `tool:specs-json [NAMES...]` - JSON array of OpenAI-wire-format wrapped specs `[{type:"function", function:<spec>}]`. Filters out unavailable tools unless `SCRATCH_TOOL_SKIP_AVAILABILITY=1`. Filtered-tool warnings are deduped per process via `_TOOL_SPECS_WARNED` so a multi-phase agent that calls the function across rounds does not produce repeated noise.

Toolbox functions:
- `tool:boxes-dir` - print the toolboxes directory (honors `SCRATCH_TOOLBOXES_DIR` for tests)
- `tool:box-list` - sorted toolbox names, one per line
- `tool:box-exists NAME` - silent predicate
- `tool:box-dir NAME` - absolute path; dies if missing
- `tool:box NAME` - the headline function. Returns the toolbox's `tools.json` content (the full `{description, tools}` object) on success. On failure (is-available exits non-zero), returns the same shape with `tools` replaced by `[]` and warns ONCE per process via `_TOOLBOX_WARNED`. Dies on unknown toolbox or malformed `tools.json`. Honors `SCRATCH_TOOL_SKIP_AVAILABILITY=1` for tests.

A toolbox is a named bundle of tool names with its own `is-available` gate. See the "Toolboxes" section below for the layout and the three reference toolboxes.
- `tool:available NAME` - runs `is-available` with the env contract; captures stderr in `_TOOL_AVAILABILITY_ERR`
- `tool:invoke NAME ARGS_JSON` - synchronously execute `main` with the env contract. Captures stdout into `_TOOL_INVOKE_STDOUT` and stderr into `_TOOL_INVOKE_STDERR` via tempfile redirects (NOT process substitution, to preserve exit codes). Returns the tool's exit code. Returns 127 if `is-available` fails first.
- `tool:invoke-parallel CALLS_JSON` - parallel execution via background jobs + wait. `CALLS_JSON` is a JSON array of `{id, name, args}` matching the OpenAI tool_calls shape. Forks one bg job per call, captures each tool's streams to numbered temp files in a `tmp:make`-allocated workdir (in the parent shell, NOT in subshells, because `tmp:make`'s registry lives in parent process memory). Results assemble in input order regardless of completion order. Failures encode as `ok:false`; silent failures get a synthesized `ERROR: tool '<name>' exited with status <code>` fallback.

Environment contract for tool main scripts:
- `SCRATCH_TOOL_ARGS_JSON` - LLM args as JSON object
- `SCRATCH_TOOL_DIR` - the tool's own directory (for sibling files)
- `SCRATCH_HOME` - scratch repo root (so bash tools can `source "$SCRATCH_HOME/lib/..."`)
- `SCRATCH_PROJECT` and `SCRATCH_PROJECT_ROOT` - only set if `project:detect` succeeds; tools should test `[[ -n ${SCRATCH_PROJECT:-} ]]`

### `lib/agent.sh`

Agent layer.
Depends on `base.sh`, `project.sh`, `prompt.sh`, `model.sh`, `chat.sh`, `tool.sh`.
Requires `jq`.

An agent is a self-contained directory under `agents/<name>/` with three required files:
- `spec.json` - metadata: `.name` and `.description`. Not executable.
- `run` - the executable entrypoint, any language. Reads stdin for the user input, prints the final response to stdout, logs to stderr.
- `is-available` - bash script that doubles as runtime gate AND dependency manifest. Sources `lib/base.sh` and calls `has-commands` for any external programs the agent needs. The doctor scanner picks up these declarations and attributes them to `agent:<name>`. Also where policy gates live (an agent can refuse to be available unless `SCRATCH_EDIT_MODE=1`, unless cwd is inside a known project, etc.).

Unlike a tool (which the LLM invokes during a chat), an agent is a script that orchestrates its own LLM workflow. A simple agent is ~5 lines wrapping `agent:simple-completion`. A complex agent (like `agents/intuition/`) is ~80 lines that uses `accumulator`/`workers`/`chat` and multiple model profiles. The run script IS the agent; there is no JSON config naming "the model" or "the system prompt" because complex agents pick both per-phase.

Functions:
- `agent:agents-dir` - print the agents directory (honors `SCRATCH_AGENTS_DIR` for tests)
- `agent:list` - sorted agent names, one per line
- `agent:exists NAME` - silent predicate
- `agent:dir NAME` - absolute path; dies if missing
- `agent:spec NAME` - raw spec.json contents
- `agent:available NAME` - runs `is-available` with the env contract; captures stderr in `_AGENT_AVAILABILITY_ERR`. Honors `SCRATCH_AGENT_SKIP_AVAILABILITY=1`.
- `agent:run NAME` - execute `agents/NAME/run` with the env contract. Pipes stdin through, propagates stdout and exit code. Refuses to run if `agent:available` fails. Increments `SCRATCH_AGENT_DEPTH` and dies if the new depth exceeds `SCRATCH_AGENT_MAX_DEPTH` (default 8) before forking, so runaway sub-agent recursion burns out fast.
- `agent:simple-completion PROFILE PROMPT_NAME [TOOLS_JSON] [EXTRAS_JSON]` - common-case helper for single-shot agents. Reads stdin once for the user input, loads the system prompt via `prompt:load`, resolves the profile, builds the messages, optionally builds a tools array via `tool:specs-json`, merges extras (caller wins), and routes through `chat:complete-with-tools` or `chat:completion` depending on whether tools were supplied. Pipes the response through `chat:extract-content` so the agent's stdout is plain text.

Environment contract for agent run scripts:
- stdin = the user input
- stdout = the final response (plain text)
- stderr = logs / progress
- `SCRATCH_AGENT_DIR` - the agent's own directory
- `SCRATCH_HOME` - scratch repo root
- `SCRATCH_PROJECT` and `SCRATCH_PROJECT_ROOT` - only set if `project:detect` succeeds
- `SCRATCH_AGENT_DEPTH` - current recursion depth (incremented before fork)

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
- All commands declared via `has-commands` across all five scan targets (see below)
- All env vars declared via `require-env-vars` in the same scan set
- Dev tools from `.mise.toml` + GNU parallel (with `--dev`)

Scan attribution:
- `bin/scratch-<verb>` files attribute to `<verb>`
- `lib/*.sh` files attribute to the synthetic label `lib` (since library deps apply transitively to many consumers)
- `helpers/<name>` files attribute to `<name>` (e.g., `embed` for `helpers/embed`, which declares `has-commands elixir`)
- `tools/<name>/is-available` files attribute to `tool:<name>` (e.g., `tool:notify` for `tools/notify/is-available`). The `tool:` prefix disambiguates tool deps from bin/lib/helper deps in the doctor output.
- `agents/<name>/is-available` files attribute to `agent:<name>` (e.g., `agent:intuition` for `agents/intuition/is-available`). Same prefix-disambiguation rationale as tools.
- `toolboxes/<name>/is-available` files attribute to `toolbox:<name>`. Most toolboxes are pure policy gates with no binary deps of their own, so this scan target usually finds nothing - but the loop is one line and gets cross-attribution for free if a toolbox ever does declare a binary.

All six scan targets share a single `_scan-deps-in` helper - one line per target in `scan-all-deps`. The same binary may show up under multiple labels: `jq` reports as `(lib tool:notify agent:echo agent:intuition)`, surfacing the full set of consumers in one row.

Flags:
- `--fix` - prompt to install missing deps via `helpers/setup`
- `--dev` - also check developer tools

The scanner reads files with `grep` and strips the keyword prefix to extract command/env names.
Keywords are held in variables (`_KW_HAS_CMD`, `_KW_REQ_ENV`) so the literal strings never appear in code lines that would otherwise match the scanner's own grep.

### `bin/scratch-intuit` (leaf)

Run the intuition reference agent against a prompt.
Takes the prompt as positional args (joined with spaces) or reads stdin if no args are given.
Pipes through `agent:run intuition`.
Useful as a sanity gauge during development and as a wrapper for "what does my subconscious think about this?".
Set `SCRATCH_DEBUG_INTUITION=1` to see each phase's intermediate output on stderr (perception, drive:<name>, synthesis).

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

## Agents

Reusable LLM workflows live under `agents/<name>/`. Each agent is a self-contained directory with three required files (see the `lib/agent.sh` entry above for the contract). Two reference agents ship in the repo: a simple one (`echo`) and a complex one (`intuition`).

### `agents/echo/`

The first concrete agent and the canonical example of a single-shot agent built on `agent:simple-completion`.
Reads stdin, asks the model to paraphrase it back in cleaner more grammatical form, prints the result.
Useful as a smoke test for the agent layer end to end.

- `spec.json` - name + description
- `run` - 5 lines: source `lib/agent.sh`, call `agent:simple-completion fast "echo/system"`
- `is-available` - declares `curl jq bc` (the leaf binaries the helper transitively depends on through `venice:curl`)
- `data/prompts/echo/system.md` - the paraphrase prompt

### `agents/intuition/`

The complex reference agent. Demonstrates that a single agent's `run` script can compose accumulator-style preprocessing, parallel sub-completions via `workers:run-parallel`, multiple model profiles, multiple prompt files, and structured-output branching - all in plain bash.

Adapted from fnord's `AI.Agent.Intuition` (Elixir, 370 lines, 10 drives).
Bash version is structurally identical but smaller for cost reasons: 4 drives instead of 10, all phases use the `fast` profile with `venice_parameters.disable_thinking` for low latency.

Three phases:

1. **Perception** - read transcript on stdin, run a single chat completion to summarize the situation.
2. **Drive reactions (parallel)** - fan out 4 chat completions via `workers:run-parallel`, one per drive (curiosity, skepticism, pragmatism, stewardship). Each drive reacts through a different lens. Workers index into parent-shell arrays (`DRIVES`, `PERCEPTION`, `DRIVE_BASE`, etc.) and write to per-index files in a workdir tracked via `tmp:track`.
3. **Synthesis** - concatenate the reactions and run a single chat completion that synthesizes them into a coherent first-person directive.

End-to-end ~10 seconds against the real API.
Set `SCRATCH_DEBUG_INTUITION=1` to see each phase's full output on stderr labeled (`perception`, `drive:<name>`, `synthesis`) via `tui:info`.

Files:
- `agents/intuition/run` - the orchestrator (~120 lines)
- `agents/intuition/spec.json` - name + description
- `agents/intuition/is-available` - declares `curl jq bc`
- `data/prompts/intuition/perception.md` - the per-perception prompt
- `data/prompts/intuition/synthesis.md` - the cleanup-pass prompt
- `data/prompts/intuition/drive-base.md` - shared header for all drive prompts
- `data/prompts/intuition/drives/<name>.md` - one file per drive

The companion subcommand `bin/scratch-intuit` is the operator-facing entry point.

## Toolboxes

A toolbox is a named bundle of tool names with its own `is-available` gate. Lets agents reference logical bundles ("read-only filesystem", "editing", "git-archaeology") instead of enumerating tool names, and lets the policy gate live with the bundle rather than at every call site.

Layout (mirrors `tools/` and `agents/`):

```
toolboxes/<name>/
  tools.json     {"description": "...", "tools": ["tool_a", "tool_b"]}
  is-available   bash; runtime gate
```

`tools.json` is an object (not a flat array) so we have room to grow - future fields might include `requires_edit_mode`, `mutually_exclusive_with`, etc.

The `is-available` script follows the same relaxed contract as tools and agents: must source `lib/base.sh`, may declare `has-commands` for any binaries the box needs, but no requirement to declare anything if the toolbox is pure policy.

Composition with `tool:specs-json`:

```bash
tool:specs-json $(tool:box read-only | jq -r '.tools[]')
```

Three reference toolboxes ship in v1:

### `toolboxes/interactive/`

Tools that need a TTY to be useful. Gated on `[[ -t 2 ]]`. Currently contains `notify` (which uses gum and only makes sense in an interactive terminal).

- `tools.json` - `{"description": "...", "tools": ["notify"]}`
- `is-available` - sources base.sh, checks `[[ -t 2 ]]`, exits 1 with a warn otherwise

### `toolboxes/read-only/`

Tools safe to run anywhere because they do not mutate state. Always available, no policy checks. Currently contains `notify` (the same tool as `interactive/`, demonstrating that tools can appear in multiple toolboxes).

- `tools.json` - `{"description": "...", "tools": ["notify"]}`
- `is-available` - sources base.sh, no checks (always available)

### `toolboxes/editing/`

Tools that mutate state (file edits, config changes, anything that writes). Gated on `SCRATCH_EDIT_MODE=1`. Currently empty (`tools: []`) because no editing tools have been built yet. Future write-capable tools land in the array as they get built.

- `tools.json` - `{"description": "...", "tools": []}`
- `is-available` - sources base.sh, checks `SCRATCH_EDIT_MODE=1`, exits 1 with a warn otherwise. Has a TODO comment about edit mode being a placeholder until the broader concept lands.

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
| `test/08-prompt.bats` | Tests for `lib/prompt.sh` (load + render with sed-escape edge cases) using fixture prompt files under `SCRATCH_PROMPTS_DIR` |
| `test/09-accumulator.bats` | Tests for `lib/accumulator.sh` (text helpers + chat layer + reduce loop + reactive backoff) with a queued `chat:completion` stub |
| `test/10-scratch-doctor.bats` | Tests for `bin/scratch-doctor` (runs doctor against a fake `SCRATCH_HOME` under `BATS_TEST_TMPDIR` so stub subcommands never pollute the live tree) |
| `test/11-tui.bats` | Tests for `lib/tui.sh` (`tui:log` arg vs pipe dispatch, stderr-only output) |
| `test/12-tempfiles.bats` | Tests for `lib/tempfiles.sh` (`tmp:make` input validation, `tmp:cleanup` directory removal) |
| `test/13-workers.bats` | Tests for `lib/workers.sh` (`workers:cpu-count` fallbacks, `workers:run-parallel` concurrency cap, parent-array lookup) |
| `test/14-agent.bats` | Tests for `lib/agent.sh` (data access, `agent:available`, env contract for `agent:run`, recursion guard, `agent:simple-completion` with stubbed chat layer) |
| `test/90-lint.bats` | Self-reflection: shellcheck |
| `test/91-formatting.bats` | Self-reflection: shfmt drift |
| `test/92-permissions.bats` | Self-reflection: +x policy |
| `test/93-anti-slop.bats` | Self-reflection: unicode + AI attribution in unpushed commits |
| `test/94-subcommand-contract.bats` | Self-reflection: subcommands honor --help |
| `test/95-tool-contract.bats` | Self-reflection: every tool dir under `tools/` follows the structural contract (spec.json shape, name match, +x bits, is-available sources base + calls has-commands) |
| `test/96-agent-contract.bats` | Self-reflection: every agent dir under `agents/` follows the structural contract (mirror of `95-tool-contract.bats`) |
| `test/97-toolbox-contract.bats` | Self-reflection: every toolbox dir under `toolboxes/` follows the structural contract; additionally cross-references that every tool name in `tools.json` resolves to an existing tool |
| `test/integration/00-venice.bats` | Opt-in integration tests against the real Venice API |
| `test/integration/01-accumulator.bats` | Opt-in: accumulator end-to-end against real models |
| `test/integration/02-agent.bats` | Opt-in: echo + intuition agents end-to-end against real models |
