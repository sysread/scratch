#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Validation and setup utilities
# - this library has no dependencies or imports
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Prevent multiple inclusions
#-------------------------------------------------------------------------------
[[ "${_INCLUDED_BASE:-}" == "1" ]] && return 0
_INCLUDED_BASE=1

#-------------------------------------------------------------------------------
# Emits a message to stderr
#-------------------------------------------------------------------------------
warn() {
  echo "$*" >&2
}

export -f warn

#-------------------------------------------------------------------------------
# Emit a message to stderr and return failure
#-------------------------------------------------------------------------------
die() {
  warn "$*"
  return 1
}

export -f die

#-------------------------------------------------------------------------------
# Requires bash to be at least the specified version string.
# Accepts major or major.minor (patch ignored). Default is 5.0.
#
# Examples:
#   has-min-bash-version           # default minimum version 5.0
#   has-min-bash-version 5.3       # major.minor
#-------------------------------------------------------------------------------
has-min-bash-version() {
  local req="${1:-5}"
  local re='^[0-9]+(\.[0-9]+)?$'

  if ! [[ $req =~ $re ]]; then
    warn "Invalid version string: $req"
    exit 1
  fi

  local req_major="${req%%.*}"
  local req_minor="${req#*.}"

  if [[ $req == "$req_major" ]]; then
    req_minor=0
  fi

  local required_version="${req_major}.${req_minor}"
  local cur_major=${BASH_VERSINFO[0]}
  local cur_minor=${BASH_VERSINFO[1]}

  if ((cur_major < req_major)) || { ((cur_major == req_major)) && ((cur_minor < req_minor)); }; then
    warn "Minimum required bash version is ${required_version} or higher."
    warn "Installed version: ${BASH_VERSION}"

    case "$OSTYPE" in
      darwin*) warn "Update with homebrew: brew update && brew upgrade bash" ;;
      linux*) warn "Update with your package manager, e.g.: sudo apt-get update && sudo apt-get install bash" ;;
      *) ;;
    esac

    exit 1
  fi
}

export -f has-min-bash-version

#-------------------------------------------------------------------------------
# Requires that one or more commands are available in PATH.
#
# When a command is not found, the error message includes an install hint if
# the binary name does not match the package name.
#
# Examples:
#   has-commands git
#   has-commands jq gum curl
#-------------------------------------------------------------------------------
declare -A _INSTALL_HINTS=(
  [gcloud]="brew install google-cloud-sdk"
  [flock]="brew install flock"
)

# On Linux, override hints where the package name differs from macOS
if [[ "${OSTYPE:-}" == linux* ]]; then
  _INSTALL_HINTS[flock]="apt-get install util-linux"
fi

has-commands() {
  local hint
  for cmd in "$@"; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      hint="${_INSTALL_HINTS[$cmd]:-}"
      hint="${hint:-brew install $cmd}"
      die "$cmd not found on PATH. Install it: $hint"
    fi
  done
}

export -f has-commands

#-------------------------------------------------------------------------------
# Requires that one or more environment variables are set and non-empty.
#
# Examples:
#   require-env-vars FOO
#   require-env-vars API_KEY API_URL
#-------------------------------------------------------------------------------
require-env-vars() {
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      die "Missing required env var: $var"
    fi
  done
}

export -f require-env-vars

#-------------------------------------------------------------------------------
# Declares env vars that the calling script reads. Informational only -
# scratch-doctor scans these to build a complete env var inventory with
# per-component attribution. Does not validate or require the var to be set.
#
# Examples:
#   uses-env-vars SCRATCH_LOG_LEVEL
#   uses-env-vars SCRATCH_CONFIG_DIR SCRATCH_PROJECTS_DIR
#-------------------------------------------------------------------------------
uses-env-vars() { :; }

export -f uses-env-vars

#-------------------------------------------------------------------------------
# Same as uses-env-vars, but marks the var as a secret. Doctor masks the
# value in its output instead of displaying it in the clear.
#
# Examples:
#   uses-secret-env-vars VENICE_API_KEY
#   uses-secret-env-vars SCRATCH_VENICE_API_KEY VENICE_API_KEY
#-------------------------------------------------------------------------------
uses-secret-env-vars() { :; }

export -f uses-secret-env-vars

#-------------------------------------------------------------------------------
# describe-env-var NAME "one-line purpose"
#
# Attaches a short purpose string to an env var. Purely informational -
# scratch-doctor collates descriptions across declaration sites (pipe-
# joined, deduplicated) and shows them in its env var table. Runtime
# no-op. Call once per var; multiple calls for the same var accumulate.
#
# Examples:
#   describe-env-var SCRATCH_LOG_LEVEL "log verbosity (info, debug, warn)"
#-------------------------------------------------------------------------------
describe-env-var() { :; }

export -f describe-env-var

uses-env-vars SCRATCH_HOME
describe-env-var SCRATCH_HOME "absolute path to the scratch install root"
