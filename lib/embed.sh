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

_EMBED_SCRIPT="$_EMBED_SCRIPTDIR/../libexec/embed.exs"
_EMBED_CXX="${CXX:-c++} -Wno-error=missing-template-arg-list-after-template-kw"

#-------------------------------------------------------------------------------
# embed:file PATH
#
# Embed the contents of a file. Prints the embedding as a JSON array of
# floats on stdout.
#-------------------------------------------------------------------------------
embed:file() {
  CXX="$_EMBED_CXX" elixir "$_EMBED_SCRIPT" "$1"
}

export -f embed:file

#-------------------------------------------------------------------------------
# embed:text TEXT
#
# Embed a text string. Prints the embedding as a JSON array of floats
# on stdout.
#-------------------------------------------------------------------------------
embed:text() {
  printf '%s' "$1" | CXX="$_EMBED_CXX" elixir "$_EMBED_SCRIPT" -
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
  CXX="$_EMBED_CXX" elixir "$_EMBED_SCRIPT" -n "$workers"
}

export -f embed:pool
