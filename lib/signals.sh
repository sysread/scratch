#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Signal handler registry
#
# Provides a centralized, named-handler registry for process signals.
# Multiple subsystems (tempfile cleanup, pipeline shutdown, debug logging)
# can register handlers independently without clobbering each other.
#
# Supported signals: EXIT, INT, TERM, HUP.
#
# Handlers are identified by name and fire in registration order (FIFO).
# Registering the same name twice replaces the previous command.
# Unregistering a name removes it; unregistering an unknown name is a
# no-op.
#
# EXIT-fires-on-all-paths:
#   When _signal:dispatch handles INT/TERM/HUP, it runs all handlers for
#   that signal and then calls exit with the conventional code (128 +
#   signum). That exit triggers the EXIT trap, so EXIT handlers fire on
#   every termination path. This means cleanup handlers should register
#   on EXIT only, not on all four signals. Signal-specific handlers
#   (e.g., killing a process group on INT) register on their signal.
#
# Handler execution:
#   Each handler command is eval'd with || true so one failing handler
#   does not prevent subsequent handlers from running. If a handler calls
#   exit itself, remaining handlers for that signal are skipped (but EXIT
#   handlers still fire via the normal bash exit-trap mechanism).
#
# Subshell safety:
#   _signal:install-trap skips when BASHPID != $$ to avoid interfering
#   with the parent's trap state. Subshells inherit the parent's traps,
#   and the parent's cleanup fires when the parent exits.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_SIGNALS:-}" == "1" ]] && return 0
_INCLUDED_SIGNALS=1

_SIGNALS_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_SIGNALS_SCRIPTDIR/base.sh"

#-------------------------------------------------------------------------------
# Handler storage: parallel indexed arrays per signal.
# Names and commands are kept in lockstep - names[i] corresponds to cmds[i].
#-------------------------------------------------------------------------------
declare -ag _SIGNAL_HANDLERS_EXIT_NAMES=()
declare -ag _SIGNAL_HANDLERS_EXIT_CMDS=()
declare -ag _SIGNAL_HANDLERS_INT_NAMES=()
declare -ag _SIGNAL_HANDLERS_INT_CMDS=()
declare -ag _SIGNAL_HANDLERS_TERM_NAMES=()
declare -ag _SIGNAL_HANDLERS_TERM_CMDS=()
declare -ag _SIGNAL_HANDLERS_HUP_NAMES=()
declare -ag _SIGNAL_HANDLERS_HUP_CMDS=()

#-------------------------------------------------------------------------------
# Supported signals and their conventional exit codes (128 + signum).
#-------------------------------------------------------------------------------
declare -gA _SIGNAL_EXIT_CODES=(
  [INT]=130
  [TERM]=143
  [HUP]=129
)

#-------------------------------------------------------------------------------
# _signal:validate-signal SIGNAL
#
# Return 0 if SIGNAL is supported, die otherwise.
#-------------------------------------------------------------------------------
_signal:validate-signal() {
  local sig="$1"
  case "$sig" in
    EXIT | INT | TERM | HUP) return 0 ;;
    *)
      die "signal:register: unsupported signal: $sig (expected EXIT, INT, TERM, or HUP)"
      return 1
      ;;
  esac
}

export -f _signal:validate-signal

#-------------------------------------------------------------------------------
# _signal:dispatch SIGNAL
#
# Trap handler. Runs all registered handlers for SIGNAL in FIFO order.
# For INT/TERM/HUP, exits with the conventional code after all handlers
# run. For EXIT, just returns (the shell is already exiting).
#-------------------------------------------------------------------------------
_signal:dispatch() {
  local sig="$1"

  # shellcheck disable=SC2178
  local -n _sd_names="_SIGNAL_HANDLERS_${sig}_NAMES"
  # shellcheck disable=SC2178
  local -n _sd_cmds="_SIGNAL_HANDLERS_${sig}_CMDS"

  local i
  for i in "${!_sd_names[@]}"; do
    eval "${_sd_cmds[$i]}" || true
  done

  # For non-EXIT signals, exit with the conventional code.
  # This triggers the EXIT trap, so EXIT handlers fire automatically.
  if [[ -n "${_SIGNAL_EXIT_CODES[$sig]:-}" ]]; then
    exit "${_SIGNAL_EXIT_CODES[$sig]}"
  fi
}

export -f _signal:dispatch

#-------------------------------------------------------------------------------
# _signal:install-trap SIGNAL
#
# Set the trap for SIGNAL to call _signal:dispatch. Idempotent - setting
# the same trap string multiple times is harmless.
#
# Skipped in subshells (BASHPID != $$) to avoid interfering with the
# parent's trap state. See lib/tempfiles.sh header for the full rationale.
#-------------------------------------------------------------------------------
_signal:install-trap() {
  local sig="$1"

  if [[ "$BASHPID" != "$$" ]]; then
    return 0
  fi

  # shellcheck disable=SC2064
  trap "_signal:dispatch $sig" "$sig"
}

export -f _signal:install-trap

#-------------------------------------------------------------------------------
# signal:register SIGNAL NAME CMD
#
# Register a named handler for SIGNAL. If a handler with the same name
# already exists for this signal, its command is replaced. Otherwise the
# handler is appended (FIFO order).
#
# Installs the actual trap on first registration for a given signal.
#-------------------------------------------------------------------------------
signal:register() {
  local sig="$1"
  local name="$2"
  local cmd="$3"

  _signal:validate-signal "$sig" || return 1

  if [[ -z "$name" ]]; then
    die "signal:register: name must not be empty"
    return 1
  fi
  if [[ -z "$cmd" ]]; then
    die "signal:register: command must not be empty"
    return 1
  fi

  # shellcheck disable=SC2178
  local -n _sr_names="_SIGNAL_HANDLERS_${sig}_NAMES"
  # shellcheck disable=SC2178
  local -n _sr_cmds="_SIGNAL_HANDLERS_${sig}_CMDS"

  # Check for existing handler with this name
  local i
  for i in "${!_sr_names[@]}"; do
    if [[ "${_sr_names[$i]}" == "$name" ]]; then
      _sr_cmds[i]="$cmd"
      return 0
    fi
  done

  # New handler - append
  _sr_names+=("$name")
  _sr_cmds+=("$cmd")

  _signal:install-trap "$sig"
}

export -f signal:register

#-------------------------------------------------------------------------------
# signal:unregister SIGNAL NAME
#
# Remove a named handler. Idempotent - unregistering an unknown name
# returns 0. If no handlers remain for the signal, the trap is reset.
#-------------------------------------------------------------------------------
signal:unregister() {
  local sig="$1"
  local name="$2"

  _signal:validate-signal "$sig" || return 1

  # shellcheck disable=SC2178
  local -n _su_names="_SIGNAL_HANDLERS_${sig}_NAMES"
  # shellcheck disable=SC2178
  local -n _su_cmds="_SIGNAL_HANDLERS_${sig}_CMDS"

  local i
  local found=0
  for i in "${!_su_names[@]}"; do
    if [[ "${_su_names[$i]}" == "$name" ]]; then
      unset '_su_names[i]'
      unset '_su_cmds[i]'
      found=1
      break
    fi
  done

  if [[ "$found" == "1" ]]; then
    # Compact arrays to remove gaps from unset
    _su_names=("${_su_names[@]}")
    _su_cmds=("${_su_cmds[@]}")

    # If no handlers remain, reset the trap
    if [[ ${#_su_names[@]} -eq 0 ]]; then
      trap - "$sig"
    fi
  fi

  return 0
}

export -f signal:unregister

#-------------------------------------------------------------------------------
# signal:list SIGNAL
#
# Print registered handler names for SIGNAL, one per line, in
# registration order. Returns 0 with no output if no handlers.
#-------------------------------------------------------------------------------
signal:list() {
  local sig="$1"

  _signal:validate-signal "$sig" || return 1

  # shellcheck disable=SC2178
  local -n _sl_names="_SIGNAL_HANDLERS_${sig}_NAMES"

  local i
  for i in "${!_sl_names[@]}"; do
    printf '%s\n' "${_sl_names[$i]}"
  done
}

export -f signal:list
