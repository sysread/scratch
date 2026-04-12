#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# TUI utilities - gum wrappers for logging, formatting, and user interaction
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Prevent multiple inclusions
#-------------------------------------------------------------------------------
[[ "${_INCLUDED_TUI:-}" == "1" ]] && return 0
_INCLUDED_TUI=1

#-------------------------------------------------------------------------------
# Imports
#-------------------------------------------------------------------------------
_TUI_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
{
  source "$_TUI_SCRIPTDIR/base.sh"
  source "$_TUI_SCRIPTDIR/termio.sh"
  source "$_TUI_SCRIPTDIR/tempfiles.sh"
}

has-commands gum

#-------------------------------------------------------------------------------
# tui:log LEVEL [ARGS...]
#
# Log a structured message to stderr via gum log. The dispatch is purely
# argument-driven, not stdin-driven, so a script can call tui:warn from
# anywhere (TTY, pipe, redirect) and the message lands on stderr. The
# original "is stdin a TTY" check was a foot-gun: any non-interactive
# script call (the common case) silently dropped the message.
#
# Two modes:
#
#   - Args supplied: log them directly. The first arg is the message;
#     subsequent args are key/value pairs that gum log renders as
#     structured fields.
#
#       tui:log info "Starting process"
#       tui:log error "Failed" detail "connection refused"
#
#   - No args: read stdin line by line and log each line at the given
#     level. For piping arbitrary command output through structured logging.
#
#       some_command | tui:log info
#
# Output goes to stderr unconditionally (gum log writes to stderr).
# stdout stays clean for program data per the conventions doc.
#-------------------------------------------------------------------------------
# Log level filtering. SCRATCH_LOG_LEVEL controls the minimum severity
# that produces output. Levels below the threshold return 0 silently.
# Default: info (debug is suppressed unless explicitly enabled).
#
# Level numbers are resolved by a helper function rather than an
# associative array because bash can't export associative arrays to
# subshells (and tui:log is exported).
_tui:_level-num() {
  case "$1" in
    debug) echo 0 ;;
    info) echo 1 ;;
    warn) echo 2 ;;
    error) echo 3 ;;
    *) echo 1 ;;
  esac
}

export -f '_tui:_level-num'

_TUI_MIN_LEVEL="$(_tui:_level-num "${SCRATCH_LOG_LEVEL:-info}")"
export _TUI_MIN_LEVEL

tui:log() {
  local level="$1"
  shift

  local level_n
  level_n="$(_tui:_level-num "$level")"
  if ((level_n < _TUI_MIN_LEVEL)); then
    # Drain stdin if piped, so the writer doesn't get SIGPIPE
    if (($# == 0)); then
      cat > /dev/null
    fi
    return 0
  fi

  if (($# > 0)); then
    gum log --structured --level "$level" "$@"
  else
    local line
    while IFS= read -r line; do
      gum log --structured --level "$level" "$line"
    done
  fi

  return 0
}

tui:debug() { tui:log debug "$@"; }
tui:info() { tui:log info "$@"; }
tui:warn() { tui:log warn "$@"; }
tui:error() { tui:log error "$@"; }

# Conditional variants: log only when the named env var is set (any value).
# Bypasses the global SCRATCH_LOG_LEVEL — the env var is the sole gate.
# Useful for per-feature debug output that should fire regardless of the
# global log level when explicitly enabled.
#   tui:debug-if SCRATCH_DEBUG_INDEX "summarized" file "$ident"
tui:debug-if() { [[ -n "${!1:-}" ]] && shift && gum log --structured --level debug "$@" || true; }
tui:info-if() { [[ -n "${!1:-}" ]] && shift && gum log --structured --level info "$@" || true; }
tui:warn-if() { [[ -n "${!1:-}" ]] && shift && gum log --structured --level warn "$@" || true; }
tui:error-if() { [[ -n "${!1:-}" ]] && shift && gum log --structured --level error "$@" || true; }

tui:die() {
  tui:error "$1" "${@:2}"
  die "$1"
}

export -f \
  tui:log \
  tui:debug \
  tui:info \
  tui:warn \
  tui:error \
  tui:debug-if \
  tui:info-if \
  tui:warn-if \
  tui:error-if \
  tui:die

#-------------------------------------------------------------------------------
# tui:format
#
# Render markdown via gum format when connected to a terminal.
# Falls back to plain text (cat) when piped.
#-------------------------------------------------------------------------------
tui:format() {
  if io:is-tty; then
    gum format
  else
    cat
  fi
}

export -f tui:format

#-------------------------------------------------------------------------------
# tui:spin TITLE
#
# Show a spinner while running a command piped to stdin. Stderr from the
# command is dropped. Stdout is passed through.
#-------------------------------------------------------------------------------
tui:spin() {
  local title="${1:-Working...}"
  gum spin --show-stdout --title "$title"
}

export -f tui:spin

#-------------------------------------------------------------------------------
# tui:choose VAR HEADER PROMPT [gum filter args...]
#
# Prompt the user to choose from a list on stdin using gum filter. The
# selection is assigned to the variable named by VAR (nameref).
#
# - Escape (no selection): assigns empty string, returns 0
# - Ctrl-C (abort): returns 1
#
# IMPORTANT: Under set -e, do not let the [[ -z "$var" ]] guard be the last
# statement in a function. Add an explicit return 0 after it:
#
#   tui:choose-one MY_VAR "Header" "Prompt" <<< "$options"
#   [[ -z "$MY_VAR" ]] && die "nothing selected"
#   return 0
#
# Examples:
#   tui:choose fav "FRUITS" "Pick one" <<< $'apple\nbanana\ncherry'
#-------------------------------------------------------------------------------
tui:choose() {
  local -n into="$1"
  local header="$2"
  local prompt="$3"
  local rest=("${@:4}")
  local exit_code

  # shellcheck disable=SC2034
  into="$(
    gum filter \
      --height 20 \
      --fuzzy \
      --fuzzy-sort \
      --header "$header" \
      --prompt "$prompt: " \
      --cursor-text.foreground 10 \
      --cursor-text.background 236 \
      "${rest[@]}"
  )" || {
    exit_code=$?

    # gum prints "nothing selected" to stderr on escape. We can't filter it
    # in a pipe without also filtering the interactive prompt. Instead,
    # manipulate the terminal directly to erase it.
    printf '\033[1A\033[2K' > /dev/tty

    # 130: ctrl-c, user aborted
    ((exit_code == 130)) && return 1

    # Otherwise escape - treat as non-error, empty selection
    into=""
  }

  return 0
}

export -f tui:choose

#-------------------------------------------------------------------------------
# tui:choose-one VAR HEADER PROMPT [gum filter args...]
#
# Like tui:choose but limited to a single selection. Auto-selects if only
# one option is available.
#-------------------------------------------------------------------------------
tui:choose-one() {
  # shellcheck disable=SC2034
  local -n into_one="$1"
  local header="$2"
  local prompt="$3"
  local rest=("${@:4}")
  tui:choose into_one "$header" "$prompt" "${rest[@]}" --limit 1 --select-if-one
}

export -f tui:choose-one

#-------------------------------------------------------------------------------
# tui:write VAR [HEADER] [PLACEHOLDER]
#
# Prompt the user for multi-line text input via gum write. The result is
# assigned to the variable named by VAR (nameref). Returns 0 on submit
# (including empty), 1 on Ctrl-C.
#
# Uses a wide, tall editor with a static cursor (no blinking) and no
# character limit.
#
# Examples:
#   tui:write question "What's your question?"
#   tui:write note "Add a note" "e.g., something important"
#-------------------------------------------------------------------------------
tui:write() {
  local -n _tw_into="$1"
  local header="${2:-}"
  local placeholder="${3:-}"

  local -a args=(
    --width 140
    --height 25
    --char-limit 0
    --cursor.mode static
  )

  [[ -n "$header" ]] && args+=(--header "$header")
  [[ -n "$placeholder" ]] && args+=(--placeholder "$placeholder")

  # Preserve gum write's exit code: 0 = submitted, 1 = escape, 130 = Ctrl-C.
  # Callers can distinguish cancel from interrupt.
  # shellcheck disable=SC2034
  _tw_into="$(gum write "${args[@]}")"
}

export -f tui:write

#-------------------------------------------------------------------------------
# tui:with-spinner TITLE COMMAND [ARGS...]
#
# Run COMMAND in the current process while showing a gum spinner. The
# spinner runs as a background process and is killed when the command
# finishes. Command output goes to stdout.
#
# Why not `gum spin -- command`: gum spin forks a subprocess, which
# loses non-exported private variables that exported bash functions
# depend on (e.g., _AGENT_SCRIPTDIR). Running in-process preserves
# the full shell state.
#
# Examples:
#   tui:with-spinner "Thinking..." agent:run self-help < input.txt
#   result="$(tui:with-spinner "Indexing..." some_function)"
#-------------------------------------------------------------------------------
# Rotating status phrases for the spinner. Shuffled on each invocation
# so the user sees a different sequence every time.
_TUI_SPINNER_PHRASES=(
  "Reversing the polarity of the context window"
  "Recalibrating the embedding matrix flux"
  "Initializing quantum token shuffler"
  "Stabilizing token interference"
  "Aligning latent vector manifold"
  "Charging semantic field resonator"
  "Inverting prompt entropy"
  "Redirecting gradient descent pathways"
  "Synchronizing the decoder attention"
  "Calibrating neural activation dampener"
  "Polarizing self-attention mechanism"
  "Recharging photonic energy in the deep learning nodes"
  "Fluctuating the vector space harmonics"
  "Boosting the backpropagation neutrino field"
  "Cross-referencing the hallucination core"
  "Reticulating splines"
)

tui:with-spinner() {
  local title="$1"
  shift

  # Capture stdin so the background spinner loop doesn't consume it.
  local tmpin tmpout tmperr tmpprogress
  tmp:make tmpin "${TMPDIR:-/tmp}/scratch-spin-in.XXXXXX"
  tmp:make tmpout "${TMPDIR:-/tmp}/scratch-spin-out.XXXXXX"
  tmp:make tmperr "${TMPDIR:-/tmp}/scratch-spin-err.XXXXXX"
  tmp:make tmpprogress "${TMPDIR:-/tmp}/scratch-spin-progress.XXXXXX"
  tmp:track "${tmpout}.rc"
  cat > "$tmpin"

  # Export the progress file path so child processes (pipeline stages,
  # subshells) can write updates. Format: "done total" — two integers,
  # space-separated. When present, the spinner renders progress as
  # [done/total] pct% before the rotating phrase.
  export TUI_PROGRESS_FILE="$tmpprogress"

  # Run the command in the background, capturing stdout, stderr, and
  # exit code separately.
  {
    "$@" < "$tmpin" > "$tmpout" 2> "$tmperr"
    printf '%s' "$?" > "${tmpout}.rc"
  } &
  local work_pid=$!

  # Spin in the foreground on stderr. The spinner renders on a single
  # line using carriage return, erased when the work finishes. Only
  # renders when stderr is a TTY.
  #
  # The status text rotates through shuffled sci-fi phrases every 25
  # frames (~2.5s at 100ms/frame), starting with the caller's title.
  if [[ -t 2 ]]; then
    # Print the title as a styled prefix on its own line
    gum style --bold --foreground 212 "$title" >&2

    local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local fi=0

    # Shuffle the phrases (Fisher-Yates via $RANDOM)
    local -a phrases=("${_TUI_SPINNER_PHRASES[@]}")
    local n=${#phrases[@]}
    local j tmp
    for ((j = n - 1; j > 0; j--)); do
      local k=$((RANDOM % (j + 1)))
      tmp="${phrases[j]}"
      phrases[j]="${phrases[k]}"
      phrases[k]="$tmp"
    done

    local phrase_idx=0
    local frames_per_phrase=25
    local _pg_done _pg_total _pg_pct progress_text

    while kill -0 "$work_pid" 2> /dev/null; do
      # Read progress from the shared file if any stage has written it
      progress_text=""
      if [[ -s "$tmpprogress" ]]; then
        if read -r _pg_done _pg_total < "$tmpprogress" 2> /dev/null; then
          if [[ -n "${_pg_done:-}" && -n "${_pg_total:-}" ]] && ((_pg_total > 0)); then
            _pg_pct=$((_pg_done * 100 / _pg_total))
            progress_text="[${_pg_done}/${_pg_total}] ${_pg_pct}% · "
          fi
        fi
      fi

      printf '\r\033[2K  %s %s%s' "${frames[fi % ${#frames[@]}]}" "$progress_text" "${phrases[phrase_idx % ${#phrases[@]}]}" >&2
      fi=$((fi + 1))

      if ((fi % frames_per_phrase == 0)); then
        phrase_idx=$((phrase_idx + 1))
      fi

      sleep 0.1
    done
    # Clear both the spinner line and the title line above it so no trace
    # of the progress UI remains after the work finishes.
    # \r\033[2K erases the current line; \033[1A moves up one line.
    printf '\r\033[2K\033[1A\r\033[2K' >&2
  fi

  wait "$work_pid" 2> /dev/null || true
  local rc
  rc="$(cat "${tmpout}.rc" 2> /dev/null || echo 1)"

  # Replay stdout and stderr as if the command ran directly
  cat "$tmpout"
  cat "$tmperr" >&2

  unset TUI_PROGRESS_FILE
  rm -f "$tmpout" "$tmperr" "$tmpin" "$tmpprogress" "${tmpout}.rc"
  return "$rc"
}

export -f tui:with-spinner
