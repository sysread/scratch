#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Prompt loading and rendering
#
# Loads prompt assets stored under data/prompts/<lib-or-agent>/<name>.md and
# optionally substitutes {{var}} placeholders. Storing prompts as flat files
# next to the data they belong to keeps them out of bash heredocs (where
# escaping rules destroy LLM-friendly markdown) and lets editors and the
# anti-slop scan treat them as the documents they are.
#
# Naming convention: data/prompts/<feature>/<name>.md, one prompt per file.
# See data/prompts/README.md for the full storage convention.
#
# Tests override the lookup root via SCRATCH_PROMPTS_DIR.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_PROMPT:-}" == "1" ]] && return 0
_INCLUDED_PROMPT=1

_PROMPT_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_PROMPT_SCRIPTDIR/base.sh"

#-------------------------------------------------------------------------------
# prompt:dir
#
# Print the directory under which prompt files are resolved. Honors
# SCRATCH_PROMPTS_DIR when set (used by tests); otherwise resolves to
# the repo's data/prompts directory next to lib/.
#-------------------------------------------------------------------------------
prompt:dir() {
  if [[ -n "${SCRATCH_PROMPTS_DIR:-}" ]]; then
    printf '%s' "$SCRATCH_PROMPTS_DIR"
  else
    printf '%s' "$_PROMPT_SCRIPTDIR/../data/prompts"
  fi
}

export -f prompt:dir

#-------------------------------------------------------------------------------
# prompt:load NAME
#
# Print the contents of the prompt file at "<prompts dir>/<NAME>.md".
# NAME may contain slashes (e.g. "accumulator/system"). Dies with the
# resolved path if the file is missing, so the error makes it obvious
# whether the lookup root or the file name is at fault.
#-------------------------------------------------------------------------------
prompt:load() {
  local name="$1"
  local path
  path="$(prompt:dir)/${name}.md"

  [[ -f "$path" ]] || die "prompt: not found: $path"

  cat "$path"
}

export -f prompt:load

#-------------------------------------------------------------------------------
# prompt:render NAME [VAR=VALUE ...]
#
# Like prompt:load, but additionally substitutes {{var}} placeholders with
# the supplied values. Substitution is literal: no nesting, no escaping
# of HTML, no fancy templating. Variables not supplied are left as-is so
# missing placeholders are visible in test output rather than silently
# dropped.
#
# Implementation uses bash's ${var//pattern/replacement} parameter
# expansion rather than sed. Parameter expansion handles values
# containing literal newlines, which sed's replacement side does not
# (sed treats the replacement as single-line by default), and operates
# on the bash variable directly so there is no stream lifecycle to
# worry about.
#
# Escape rules in the replacement side:
# - bash 5.x treats `&` as a backreference to the matched text (same as
#   sed), so we escape `&` to `\&` in values before substitution.
# - `\` itself escapes the next char in the replacement, so we double
#   backslashes too.
# - Everything else (`{`, `}`, `|`, `/`, newlines) is literal.
#
# Example:
#   prompt:render accumulator/system user_prompt="$prompt" question="$q" notes="$n"
#-------------------------------------------------------------------------------
prompt:render() {
  local name="$1"
  shift

  local content
  # Capture explicitly so prompt:load's die propagates - bash command
  # substitution otherwise discards the failure exit code when assigning
  # to a local declared on the same line.
  content="$(prompt:load "$name")" || return 1

  local arg
  local key
  local value
  local placeholder
  for arg in "$@"; do
    key="${arg%%=*}"
    value="${arg#*=}"
    # Escape backslashes first, then ampersands. Order matters: if we
    # escaped & first, the resulting \& would get its backslash doubled
    # to \\& in the next pass.
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    placeholder="{{${key}}}"
    content="${content//${placeholder}/${value}}"
  done

  printf '%s' "$content"
}

export -f prompt:render
