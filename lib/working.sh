#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Progress helper wrapper
#
# Bash wrapper around libexec/working.exs. Same pattern as lib/embed.sh:
# strip BASH_FUNC_* exports before invoking elixir, since `elixir` is a
# #!/bin/sh script and macOS /bin/sh in POSIX mode chokes when it tries
# to import bash 5 functions that use [[ -v array[$key] ]] syntax.
#
# Owl is pure Elixir (no NIFs), so we don't need the CXX workaround that
# embed.sh has for EXLA.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_WORKING:-}" == "1" ]] && return 0
_INCLUDED_WORKING=1

_WORKING_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_WORKING_SCRIPTDIR/base.sh"

has-commands elixir

_WORKING_SCRIPT="$_WORKING_SCRIPTDIR/../libexec/working.exs"

#-------------------------------------------------------------------------------
# working:run [WORKING_ARGS...]
#
# Invoke libexec/working.exs with a clean environment. Reads stdin, writes
# stdout/stderr to the terminal directly (for Owl's live rendering). All
# args after the function name are passed through to working.exs verbatim.
#
# Example:
#   ( producer | consumer ) 2>&1 | working:run --total 100 --match '^ok '
#-------------------------------------------------------------------------------
working:run() {
  # Forward locale vars so Elixir's IO knows it can emit UTF-8. Without
  # them, the BEAM falls back to Latin-1 and prints non-ASCII codepoints
  # as \x{NNNN} escape sequences — which means our braille spinner and
  # ─ separator render as literal escape strings instead of characters.
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    TERM="${TERM:-xterm}" \
    LANG="${LANG:-en_US.UTF-8}" \
    LC_ALL="${LC_ALL:-${LANG:-en_US.UTF-8}}" \
    LC_CTYPE="${LC_CTYPE:-${LANG:-en_US.UTF-8}}" \
    elixir "$_WORKING_SCRIPT" "$@"
}

export -f working:run
