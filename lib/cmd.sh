#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Declarative command definition library
#
# Provides a structured way to define CLI commands with typed arguments, flags,
# help text generation, and automatic parsing. Commands declare their interface
# using cmd:define, cmd:required-arg, cmd:optional-arg, and cmd:flag, then call
# cmd:parse to handle argv. Parsed values are retrieved via cmd:get, cmd:get-into,
# and cmd:has.
#
# Lifecycle:
#   cmd:define / cmd:*-arg / cmd:flag / cmd:define-cli-usage  (registration)
#                          |
#                    cmd:parse "$@"                           (parse + meta-commands)
#                          |
#                    cmd:validate                             (check required args)
#                          |
#                    cmd:get / cmd:has                        (retrieve values)
#
# Example:
#   cmd:define "hello" "Says hello to someone"
#   cmd:required-arg "--name" "-n" "Name to greet" "string"
#   cmd:optional-arg "--greeting" "-g" "Greeting to use" "string" "Hello"
#   cmd:flag "--shout" "-s" "Whether to shout the greeting"
#
#   cmd:parse "$@"
#   if ! cmd:validate; then
#     cmd:usage
#   fi
#
#   cmd:get-into NAME --name
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_CMD:-}" == "1" ]] && return 0
_INCLUDED_CMD=1

#-------------------------------------------------------------------------------
# Import dependencies
#
# We source base.sh for die/warn but intentionally do NOT source tui.sh here.
# tui.sh requires gum+jq at source time, which would make even the fast
# "synopsis" path depend on those binaries. Instead, cmd:usage sources tui.sh
# lazily and falls back to plain cat if gum isn't available.
#-------------------------------------------------------------------------------
_CMD_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_CMD_SCRIPTDIR/base.sh"

#-------------------------------------------------------------------------------
# State storage
#
# All state is in global variables prefixed _CMD_ to avoid collisions with
# command scripts. Associative arrays are keyed by the long flag name (e.g.
# "--name"). The _CMD_ARG_ORDER indexed array preserves declaration order for
# deterministic help output.
#-------------------------------------------------------------------------------
declare -g _CMD_NAME=""
declare -g _CMD_DESC=""
declare -gA _CMD_ARG_SHORT=()          # [--name] -> "-n" (or "" for no short form)
declare -gA _CMD_ARG_DESC=()           # [--name] -> "Name to greet"
declare -gA _CMD_ARG_TYPE=()           # [--name] -> "string" | "integer" | "enum" | "boolean"
declare -gA _CMD_ARG_DEFAULT=()        # [--name] -> default value (absent key = required)
declare -gA _CMD_ARG_REQUIRED=()       # [--name] -> "1" if required
declare -gA _CMD_ARG_ENUM=()           # [--method] -> "GET|POST|PATCH|DELETE"
declare -ga _CMD_ARG_ORDER=()          # declaration order
declare -gA _CMD_PARSED=()             # [--name] -> parsed value
declare -ga _CMD_POSITIONALS=()        # args after "--" or unrecognized non-flag tokens
declare -ga _CMD_ERRORS=()             # accumulated error messages
declare -ga _CMD_CLI_USAGE=()          # extra CLI-only help sections
declare -gA _CMD_ARG_OPTIONAL_VALUE=() # [--team] -> "1" if optional-value (value not required)
declare -gA _CMD_ARG_SEEN=()           # [--flag] -> "1" if seen during parse (all flag types)
declare -ga _CMD_ENV_ORDER=()          # env var declaration order
declare -gA _CMD_ENV_DESC=()           # [VARNAME] -> description
declare -gA _CMD_ENV_DEFAULT=()        # [VARNAME] -> default value (absent key = required)

#-------------------------------------------------------------------------------
# cmd:define NAME DESC
#
# Register the command's name and one-line description. The description is used
# for synopsis output (consumed by bin/dispatch to build the top-level help).
#-------------------------------------------------------------------------------
cmd:define() {
  _CMD_NAME="$1"
  _CMD_DESC="$2"
}

export -f cmd:define

#-------------------------------------------------------------------------------
# cmd:required-arg LONG SHORT DESC TYPE [ENUM_VALUES]
#
# Register a required named argument. SHORT may be "" if there is no short form.
# TYPE is metadata for help text - not validated at runtime. For enum types,
# pass pipe-delimited values as the last argument.
#
# Examples:
#   cmd:required-arg "--name" "-n" "Name to greet" "string"
#   cmd:required-arg "--method" "-m" "HTTP method" "enum" "GET|POST|PATCH|DELETE"
#-------------------------------------------------------------------------------
cmd:required-arg() {
  local long="$1"
  local short="$2"
  local desc="$3"
  local type="$4"

  _CMD_ARG_SHORT["$long"]="$short"
  _CMD_ARG_DESC["$long"]="$desc"
  _CMD_ARG_TYPE["$long"]="$type"
  _CMD_ARG_REQUIRED["$long"]=1
  _CMD_ARG_ORDER+=("$long")

  if [[ "$type" == "enum" && -n "${5:-}" ]]; then
    _CMD_ARG_ENUM["$long"]="$5"
  fi
}

export -f cmd:required-arg

#-------------------------------------------------------------------------------
# cmd:optional-arg LONG SHORT DESC TYPE DEFAULT [ENUM_VALUES]
#
# Register an optional named argument with a default value. SHORT may be "" if
# there is no short form.
#
# Examples:
#   cmd:optional-arg "--greeting" "-g" "Greeting to use" "string" "Hello"
#   cmd:optional-arg "--format" "" "Output format" "enum" "json" "json|yaml|text"
#-------------------------------------------------------------------------------
cmd:optional-arg() {
  local long="$1"
  local short="$2"
  local desc="$3"
  local type="$4"
  local default="$5"

  _CMD_ARG_SHORT["$long"]="$short"
  _CMD_ARG_DESC["$long"]="$desc"
  _CMD_ARG_TYPE["$long"]="$type"
  _CMD_ARG_DEFAULT["$long"]="$default"
  _CMD_ARG_ORDER+=("$long")

  if [[ "$type" == "enum" && -n "${6:-}" ]]; then
    _CMD_ARG_ENUM["$long"]="$6"
  fi
}

export -f cmd:optional-arg

#-------------------------------------------------------------------------------
# cmd:flag LONG SHORT DESC
#
# Register a boolean flag. Flags default to off (0) and are set to on (1) when
# present in argv.
#
# Examples:
#   cmd:flag "--shout" "-s" "Whether to shout the greeting"
#   cmd:flag "--verbose" "" "Enable verbose output"
#-------------------------------------------------------------------------------
cmd:flag() {
  local long="$1"
  local short="$2"
  local desc="$3"

  _CMD_ARG_SHORT["$long"]="$short"
  _CMD_ARG_DESC["$long"]="$desc"
  _CMD_ARG_TYPE["$long"]="boolean"
  _CMD_ARG_DEFAULT["$long"]="0"
  _CMD_ARG_ORDER+=("$long")
}

export -f cmd:flag

#-------------------------------------------------------------------------------
# cmd:optional-value-arg LONG SHORT DESC TYPE
#
# Register a flag that optionally consumes a value. Supports three states:
#
#   Not passed        -> cmd:has returns false, cmd:get returns ""
#   Passed bare       -> cmd:has returns true,  cmd:get returns ""
#   Passed with value -> cmd:has returns true,  cmd:get returns the value
#
# Example:
#   cmd:optional-value-arg "--team" "-t" "Team name" "string"
#   # --team Results  -> filter by "Results"
#   # --team          -> interactive team picker
#   # (omitted)       -> no team filtering
#-------------------------------------------------------------------------------
cmd:optional-value-arg() {
  local long="$1"
  local short="$2"
  local desc="$3"
  local type="$4"

  _CMD_ARG_SHORT["$long"]="$short"
  _CMD_ARG_DESC["$long"]="$desc"
  _CMD_ARG_TYPE["$long"]="$type"
  _CMD_ARG_DEFAULT["$long"]=""
  _CMD_ARG_OPTIONAL_VALUE["$long"]=1
  _CMD_ARG_ORDER+=("$long")
}

export -f cmd:optional-value-arg

#-------------------------------------------------------------------------------
# cmd:define-cli-usage SECTION_HEADER CONTENT
#
# Add an extra section to the CLI help output (--help). These sections appear
# after the OPTIONS block in declaration order.
#
# Example:
#   cmd:define-cli-usage "EXAMPLES" "$(cat <<'EOF'
#     scratch hello --name World
#     scratch hello --name World --shout
#   EOF
#   )"
#-------------------------------------------------------------------------------
cmd:define-cli-usage() {
  local header="$1"
  local content="$2"

  _CMD_CLI_USAGE+=("${header}|${content}")
}

export -f cmd:define-cli-usage

#-------------------------------------------------------------------------------
# cmd:define-env-var VARNAME DESC [DEFAULT]
#
# Register an environment variable that this command reads at runtime. Rendered
# in an "ENV VARS" section in CLI help. Documentation-only - does not validate.
#
# Examples:
#   cmd:define-env-var "API_KEY" "API key for the service"
#   cmd:define-env-var "API_URL" "Override the default URL" "https://api.example.com"
#-------------------------------------------------------------------------------
cmd:define-env-var() {
  local var="$1"
  local desc="$2"

  _CMD_ENV_ORDER+=("$var")
  _CMD_ENV_DESC["$var"]="$desc"

  if (($# >= 3)); then
    _CMD_ENV_DEFAULT["$var"]="$3"
  fi
}

export -f cmd:define-env-var

#-------------------------------------------------------------------------------
# _cmd:resolve-flag FLAG
#
# (Private) Maps a flag (long or short form) to its canonical long form. Prints
# the long form to stdout. Returns 1 if the flag is not recognized.
#-------------------------------------------------------------------------------
_cmd:resolve-flag() {
  local flag="$1"

  # Direct long-form match
  if [[ -v '_CMD_ARG_TYPE[$flag]' ]]; then
    printf '%s' "$flag"
    return 0
  fi

  # Short-form match
  local long
  for long in "${_CMD_ARG_ORDER[@]}"; do
    if [[ "${_CMD_ARG_SHORT[$long]}" == "$flag" ]]; then
      printf '%s' "$long"
      return 0
    fi
  done

  return 1
}

export -f _cmd:resolve-flag

#-------------------------------------------------------------------------------
# cmd:parse "$@"
#
# Parse the command's argv into the internal _CMD_PARSED store. Handles three
# meta-commands that cause an immediate exit:
#
#   synopsis    - print the one-line description and exit 0 (for bin/dispatch)
#   --help / -h - print formatted usage and exit 0
#
# After cmd:parse returns, values are available via cmd:get / cmd:get-into /
# cmd:has, and positional args via cmd:rest.
#-------------------------------------------------------------------------------
cmd:parse() {
  local long
  local resolved

  # Fast path: synopsis is the first thing dispatch calls on every subcommand
  # to build the help listing. Must respond quickly without heavy deps.
  if [[ "${1:-}" == "synopsis" ]]; then
    printf '%s\n' "$_CMD_DESC"
    exit 0
  fi

  # Initialize _CMD_PARSED with defaults for optional args and flags.
  # Required args are left absent - their absence is what cmd:validate checks.
  for long in "${_CMD_ARG_ORDER[@]}"; do
    if [[ -v '_CMD_ARG_DEFAULT[$long]' ]]; then
      _CMD_PARSED["$long"]="${_CMD_ARG_DEFAULT[$long]}"
    fi
  done

  while (($#)); do
    case "$1" in
      --help | -h | help)
        cmd:usage
        exit 0
        ;;

      --)
        shift
        while (($#)); do
          _CMD_POSITIONALS+=("$1")
          shift
        done
        break
        ;;

      -*)
        if resolved="$(_cmd:resolve-flag "$1")"; then
          _CMD_ARG_SEEN["$resolved"]=1

          if [[ "${_CMD_ARG_TYPE[$resolved]}" == "boolean" ]]; then
            _CMD_PARSED["$resolved"]="1"
          elif [[ "${_CMD_ARG_OPTIONAL_VALUE[$resolved]:-}" == "1" ]]; then
            # Peek at next token: consume as value if it doesn't look like a flag
            if [[ $# -ge 2 && "$2" != -* ]]; then
              _CMD_PARSED["$resolved"]="$2"
              shift
            else
              _CMD_PARSED["$resolved"]=""
            fi
          else
            if [[ $# -lt 2 || "$2" == -* ]]; then
              _CMD_ERRORS+=("$1 requires a value")
            else
              _CMD_PARSED["$resolved"]="$2"
              shift
            fi
          fi
        else
          _CMD_ERRORS+=("unknown argument: $1")
        fi
        ;;

      *)
        _CMD_POSITIONALS+=("$1")
        ;;
    esac
    shift
  done
}

export -f cmd:parse

#-------------------------------------------------------------------------------
# cmd:validate
#
# Check that all required arguments were provided. Returns 0 if no errors, 1
# otherwise.
#-------------------------------------------------------------------------------
cmd:validate() {
  local long
  for long in "${_CMD_ARG_ORDER[@]}"; do
    if [[ "${_CMD_ARG_REQUIRED[$long]:-}" == "1" ]] && [[ ! -v '_CMD_PARSED[$long]' ]]; then
      _CMD_ERRORS+=("missing required argument: $long")
    fi
  done

  ((${#_CMD_ERRORS[@]} == 0))
}

export -f cmd:validate

#-------------------------------------------------------------------------------
# cmd:get LONG
#
# Print the parsed value for the given long flag to stdout.
#-------------------------------------------------------------------------------
cmd:get() {
  printf '%s' "${_CMD_PARSED[$1]:-}"
}

export -f cmd:get

#-------------------------------------------------------------------------------
# cmd:get-into VARNAME LONG
#
# Set the caller's variable VARNAME to the parsed value via nameref. Avoids the
# subshell overhead of $(cmd:get ...).
#-------------------------------------------------------------------------------
cmd:get-into() {
  local -n _cmd_ref="$1"
  _cmd_ref="${_CMD_PARSED[$2]:-}"
}

export -f cmd:get-into

#-------------------------------------------------------------------------------
# cmd:has LONG
#
# Test whether a flag was explicitly passed on the command line.
#-------------------------------------------------------------------------------
cmd:has() {
  [[ "${_CMD_PARSED[$1]:-0}" == "1" ]] || [[ "${_CMD_ARG_SEEN[$1]:-}" == "1" ]]
}

export -f cmd:has

#-------------------------------------------------------------------------------
# cmd:rest
#
# Print positional arguments (after "--" or non-flag tokens), one per line.
# Returns 1 if none.
#-------------------------------------------------------------------------------
cmd:rest() {
  if ((${#_CMD_POSITIONALS[@]} == 0)); then
    return 1
  fi

  printf '%s\n' "${_CMD_POSITIONALS[@]}"
}

export -f cmd:rest

#-------------------------------------------------------------------------------
# cmd:usage [--no-extra]
#
# Print formatted help text to stderr. If _CMD_ERRORS is non-empty, prints
# the error list and exits 1. Otherwise, exits 0.
#
# Output is piped through tui:format for markdown rendering when connected to
# a TTY. Falls back to cat if tui:format is not available.
#-------------------------------------------------------------------------------
cmd:usage() {
  local show_extra=1
  local long short desc type flag_col annotation entry header content err
  local max_width i
  local -a flag_cols=()
  local -a desc_cols=()
  local -a env_name_cols=()
  local -a env_desc_cols=()
  local env_max_width env_annotation var

  if [[ "${1:-}" == "--no-extra" ]]; then
    show_extra=0
  fi

  {
    printf '# USAGE\n\n'
    # shellcheck disable=SC2016
    printf '`scratch %s [options]`\n\n' "$_CMD_NAME"

    printf '# SYNOPSIS\n\n'
    printf '%s\n\n' "$_CMD_DESC"

    # Options: two-pass rendering for aligned columns
    printf '# OPTIONS\n\n'

    flag_cols+=("\`-h\`, \`--help\`")
    desc_cols+=("Show this help message and exit")
    max_width=${#flag_cols[0]}

    for long in "${_CMD_ARG_ORDER[@]}"; do
      short="${_CMD_ARG_SHORT[$long]}"
      type="${_CMD_ARG_TYPE[$long]}"
      desc="${_CMD_ARG_DESC[$long]}"

      if [[ -n "$short" ]]; then
        flag_col="\`${short}\`, \`${long}\`"
      else
        flag_col="\`${long}\`"
      fi

      if [[ "${_CMD_ARG_OPTIONAL_VALUE[$long]:-}" == "1" ]]; then
        flag_col+=" [VALUE]"
      elif [[ "$type" != "boolean" ]]; then
        flag_col+=" VALUE"
      fi

      annotation=""
      if [[ "${_CMD_ARG_REQUIRED[$long]:-}" == "1" ]]; then
        annotation=" *(required)*"
      elif [[ -v '_CMD_ARG_DEFAULT[$long]' && "$type" != "boolean" && -n "${_CMD_ARG_DEFAULT[$long]}" ]]; then
        annotation=" (default: ${_CMD_ARG_DEFAULT[$long]})"
      fi

      if [[ -v '_CMD_ARG_ENUM[$long]' ]]; then
        annotation+=" [${_CMD_ARG_ENUM[$long]}]"
      fi

      flag_cols+=("$flag_col")
      desc_cols+=("${desc}${annotation}")

      if ((${#flag_col} > max_width)); then
        max_width=${#flag_col}
      fi
    done

    for i in "${!flag_cols[@]}"; do
      printf '  %-*s    %s\n' "$max_width" "${flag_cols[$i]}" "${desc_cols[$i]}"
    done

    # Env vars
    if ((${#_CMD_ENV_ORDER[@]} > 0)); then
      printf '\n# ENV VARS\n\n'

      env_max_width=0

      for var in "${_CMD_ENV_ORDER[@]}"; do
        env_annotation=""
        if [[ -v '_CMD_ENV_DEFAULT[$var]' ]]; then
          if [[ -n "${_CMD_ENV_DEFAULT[$var]}" ]]; then
            env_annotation=" (default: ${_CMD_ENV_DEFAULT[$var]})"
          fi
        else
          env_annotation=" *(required)*"
        fi

        env_name_cols+=("\`${var}\`")
        env_desc_cols+=("${_CMD_ENV_DESC[$var]}${env_annotation}")

        if ((${#var} + 2 > env_max_width)); then
          env_max_width=$((${#var} + 2))
        fi
      done

      for i in "${!env_name_cols[@]}"; do
        printf '  %-*s    %s\n' "$env_max_width" "${env_name_cols[$i]}" "${env_desc_cols[$i]}"
      done
    fi

    # Extra CLI-only sections
    if ((show_extra && ${#_CMD_CLI_USAGE[@]} > 0)); then
      for entry in "${_CMD_CLI_USAGE[@]}"; do
        header="${entry%%|*}"
        content="${entry#*|}"
        # shellcheck disable=SC2016
        printf '\n# %s\n\n```bash\n%s\n```\n' "$header" "$content"
      done
    fi

    # Errors
    if ((${#_CMD_ERRORS[@]} > 0)); then
      printf '\n# ERRORS\n\n'
      for err in "${_CMD_ERRORS[@]}"; do
        printf -- '- %s\n' "$err"
      done
    fi
  } | _cmd:format_help >&2

  if ((${#_CMD_ERRORS[@]} > 0)); then
    exit 1
  fi

  exit 0
}

export -f cmd:usage

#-------------------------------------------------------------------------------
# _cmd:format_help
#
# (Private) Pipe filter that renders markdown help text. Falls back to cat if
# tui:format isn't available.
#-------------------------------------------------------------------------------
_cmd:format_help() {
  if type -t tui:format &> /dev/null; then
    tui:format
  else
    cat
  fi
}

export -f _cmd:format_help
