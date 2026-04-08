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

has-commands sed

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
# _prompt:_sed-escape STRING
#
# (Private) Escape a string for use as the replacement side of a sed s|||
# command. We use | as the delimiter so / does not need escaping, but &
# (sed's whole-match backreference) and | (the delimiter itself) and \
# (escape char) all do. Backslashes first, then & and |.
#-------------------------------------------------------------------------------
_prompt:_sed-escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  s="${s//|/\\|}"
  printf '%s' "$s"
}

#-------------------------------------------------------------------------------
# prompt:render NAME [VAR=VALUE ...]
#
# Like prompt:load, but additionally substitutes {{var}} placeholders with
# the supplied values. Substitution is literal: no nesting, no escaping
# of HTML, no fancy templating. Variables not supplied are left as-is so
# missing placeholders are visible in test output rather than silently
# dropped.
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
  local escaped
  for arg in "$@"; do
    key="${arg%%=*}"
    value="${arg#*=}"
    escaped="$(_prompt:_sed-escape "$value")"
    content="$(printf '%s' "$content" | sed "s|{{${key}}}|${escaped}|g")"
  done

  printf '%s' "$content"
}

export -f prompt:render
