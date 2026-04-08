#!/usr/bin/env bash

set -euo pipefail

#-------------------------------------------------------------------------------
# Assert newer bats version to enable features like 'run' and 'load'
#-------------------------------------------------------------------------------
bats_require_minimum_version 1.5.0

#-------------------------------------------------------------------------------
# Assert that two strings are equal. On failure, print expected vs actual.
#-------------------------------------------------------------------------------
is() {
  local actual="$1"
  local expected="$2"

  [[ "$actual" = "$expected" ]] || {
    printf 'Expected: %q\n' "$expected"
    printf '  Actual: %q\n' "$actual"
    return 1
  }
}

#-------------------------------------------------------------------------------
# Print diagnostic messages to stderr, prefixed with '# '
#-------------------------------------------------------------------------------
diag() {
  printf '# %s\n' "$*" >&2
  return 0
}

#-------------------------------------------------------------------------------
# External command stubbing
#
# Unit tests should stub every external command they exercise instead of
# relying on whatever happens to be installed on the host or CI runner.
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Create an executable stub command under ${BATS_TEST_TMPDIR}/stubbin.
# Prints the full stub path on stdout.
#-------------------------------------------------------------------------------
make_stub() {
  local name="$1"
  local body="$2"
  local stubdir="${BATS_TEST_TMPDIR}/stubbin"
  local stubpath="${stubdir}/${name}"

  mkdir -p "$stubdir"
  printf '%s\n' "$body" > "$stubpath"
  chmod +x "$stubpath"
  printf '%s\n' "$stubpath"
}

#-------------------------------------------------------------------------------
# Prepend the shared stub directory to PATH once for the current test.
#-------------------------------------------------------------------------------
prepend_stub_path() {
  local stubdir="${BATS_TEST_TMPDIR}/stubbin"

  case ":${PATH}:" in
    *":${stubdir}:"*) ;;
    *) PATH="${stubdir}:${PATH}" ;;
  esac
}

#-------------------------------------------------------------------------------
# Function: shellcheck_parallel <sc-arg>... -- <file>...
#
# Run the shellcheck linter against many files in parallel using the
# bounded worker pool primitive in lib/workers.sh. Returns 0 if every
# file passed, 1 if any failed (with failing files' output printed in
# input order regardless of completion order).
#
# The linter has no native parallelism, but it is embarrassingly
# parallel per file. The `--` separator delimits linter flags from file
# paths so we don't have to fight word splitting on a quoted flag
# string.
#
# Concurrency cap defaults to workers:cpu-count (logical CPUs from
# getconf, or 8 on fallback). Override via SHELLCHECK_PARALLEL_JOBS.
#
# Output discipline: each child writes its combined stdout/stderr to a
# per-file capture file under a workdir. The parent reads them back in
# input order at the end and prints only the failures. Per-file
# diagnostics stay intact and ordered no matter which children happened
# to finish first.
#-------------------------------------------------------------------------------
shellcheck_parallel() {
  # Source the worker pool primitive from the repo lib. SCRATCH_HOME is
  # set by every bats setup() in this codebase before sourcing helpers.
  # shellcheck source=/dev/null
  source "${SCRATCH_HOME}/lib/workers.sh"

  local -a sc_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    sc_args+=("$1")
    shift
  done
  if [[ "${1:-}" != "--" ]]; then
    printf 'shellcheck_parallel: missing -- separator\n' >&2
    return 2
  fi
  shift # consume the --

  local -a SHELLCHECK_FILES=("$@")
  local count=${#SHELLCHECK_FILES[@]}
  ((count > 0)) || return 0

  local max_jobs="${SHELLCHECK_PARALLEL_JOBS:-$(workers:cpu-count)}"
  local workdir="${BATS_TEST_TMPDIR}/shellcheck-parallel.$$"
  mkdir -p "$workdir"

  # Worker function. Reads its file from SHELLCHECK_FILES at the given
  # index. Writes combined stdout/stderr to <workdir>/<i>.out and the
  # exit code to <workdir>/<i>.status. Both arrays-by-index sit in the
  # parent shell; subshells inherit them at fork time so the lookup
  # needs no marshalling.
  SHELLCHECK_ARGS=("${sc_args[@]}")
  SHELLCHECK_WORKDIR="$workdir"
  export SHELLCHECK_FILES SHELLCHECK_ARGS SHELLCHECK_WORKDIR

  # shellcheck disable=SC2329 # invoked indirectly by workers:run-parallel
  _shellcheck_worker() {
    local i="$1"
    shellcheck "${SHELLCHECK_ARGS[@]}" "${SHELLCHECK_FILES[i]}" \
      > "${SHELLCHECK_WORKDIR}/${i}.out" 2>&1
    printf '%s' "$?" > "${SHELLCHECK_WORKDIR}/${i}.status"
  }
  export -f _shellcheck_worker

  workers:run-parallel "$max_jobs" "$count" _shellcheck_worker

  local rc=0
  local i
  local file_rc
  for ((i = 0; i < count; i++)); do
    file_rc="$(cat "${workdir}/${i}.status")"
    if [[ "$file_rc" != "0" ]]; then
      rc=1
      printf '\n=== %s (exit %s) ===\n' "${SHELLCHECK_FILES[i]}" "$file_rc"
      cat "${workdir}/${i}.out"
    fi
  done

  rm -rf "$workdir"
  return "$rc"
}
