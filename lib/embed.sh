#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Embedding generation
#
# Bash wrapper around libexec/embed.exs. Sets the CXX compiler flag
# workaround for Apple clang 17+ and provides function-level entry points
# for single-text and pool modes.
#
# Being a sourced library (not a forked helper), the elixir process is a
# direct child of whatever script sources this. Signal propagation and
# pipeline cleanup work naturally — no exec indirection.
#
# Apple clang 17+ promotes -Wmissing-template-arg-list-after-template-kw
# to a hard error, breaking EXLA's NIF compilation on first run. The CXX
# override suppresses that specific error. Subsequent runs use the cached
# .so and the flag is harmless.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_EMBED:-}" == "1" ]] && return 0
_INCLUDED_EMBED=1

_EMBED_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_EMBED_SCRIPTDIR/base.sh"

has-commands elixir
uses-env-vars SCRATCH_MODEL
describe-env-var SCRATCH_MODEL "override default embedding model name"

_EMBED_SCRIPT="$_EMBED_SCRIPTDIR/../libexec/embed.exs"
_EMBED_CXX="${CXX:-c++} -Wno-error=missing-template-arg-list-after-template-kw"

#-------------------------------------------------------------------------------
# _embed:_run SCRIPT [ARGS...]
#
# Run an elixir script with a clean environment. The `elixir` command is
# a #!/bin/sh script; on macOS /bin/sh is bash 3.2 in POSIX mode, which
# chokes on exported bash 5 functions (like cmd:parse with [[ -v ]]).
# Strip BASH_FUNC_* by running under env -i with only the vars elixir
# needs. SCRATCH_MODEL is only forwarded when set to avoid overriding
# embed.exs's default model with an empty string.
#
# Filters XLA/Abseil C++ init noise from stderr — these lines come from
# the compiled NIF on each cold start and can't be silenced via Elixir's
# logger config:
#   WARNING: All log messages before absl::InitializeLog() is called...
#   I0000 00:00:<ts> <pid> cpu_client.cc:<line>] TfrtCpuClient created.
# Real Elixir/EXLA errors still pass through.
#-------------------------------------------------------------------------------
_embed:_run() {
  local -a env_args=(
    PATH="$PATH"
    HOME="$HOME"
    CXX="$_EMBED_CXX"
    TERM="${TERM:-dumb}"
  )

  # Only forward SCRATCH_MODEL if the user actually set it
  if [[ -n "${SCRATCH_MODEL:-}" ]]; then
    env_args+=(SCRATCH_MODEL="$SCRATCH_MODEL")
  fi

  env -i "${env_args[@]}" elixir "$@" \
    2> >(grep -v -E '^WARNING: All log messages before absl::InitializeLog|^I[0-9]{4} [0-9:.]+ +[0-9]+ cpu_client\.cc' >&2)
}

export -f '_embed:_run'

#-------------------------------------------------------------------------------
# embed:file PATH
#
# Embed the contents of a file. Prints the embedding as a JSON array of
# floats on stdout.
#-------------------------------------------------------------------------------
embed:file() {
  _embed:_run "$_EMBED_SCRIPT" "$1"
}

export -f embed:file

#-------------------------------------------------------------------------------
# embed:text TEXT
#
# Embed a text string. Prints the embedding as a JSON array of floats
# on stdout.
#-------------------------------------------------------------------------------
embed:text() {
  printf '%s' "$1" | _embed:_run "$_EMBED_SCRIPT" -
}

export -f embed:text

#-------------------------------------------------------------------------------
# embed:pool [WORKERS]
#
# Run the embedding pool. Reads JSONL from stdin ({id, text} per line),
# writes JSONL to stdout ({id, embedding} per line). The elixir process
# loads the model once and uses Task.Supervisor.async_stream_nolink with
# bounded concurrency.
#
# The pool self-terminates when stdin closes (broken pipe from parent
# exit), cancelling any in-flight inference tasks immediately.
#
# Default WORKERS: 4.
#-------------------------------------------------------------------------------
embed:pool() {
  local workers="${1:-4}"
  _embed:_run "$_EMBED_SCRIPT" -n "$workers"
}

export -f embed:pool
