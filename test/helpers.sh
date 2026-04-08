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
# Run the shellcheck linter against many files in parallel using a
# bounded bash worker pool. Returns 0 if every file passed, 1 if any
# failed (with the failing files' linter output printed in
# deterministic order regardless of completion order).
#
# The linter has no native parallelism, but it is embarrassingly
# parallel per file. The serial form walks files one at a time and is
# the dominant cost of the lint suite. This helper forks one process
# per file, capping concurrency at SHELLCHECK_PARALLEL_JOBS (default
# 8) via `wait -n` (bash 4.3+; scratch requires 5+).
#
# The `--` separator delimits linter flags from file paths so we
# don't have to fight word splitting on a quoted flag string.
#
# Output discipline: each child writes its combined stdout/stderr to
# a per-file capture file under BATS_TEST_TMPDIR. The parent reads
# them back in input order at the end and prints only the failures.
# This keeps per-file diagnostics intact and ordered, regardless of
# which children happened to finish first.
#-------------------------------------------------------------------------------
shellcheck_parallel() {
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

  local -a files=("$@")
  local count=${#files[@]}
  if ((count == 0)); then
    return 0
  fi

  local max_jobs="${SHELLCHECK_PARALLEL_JOBS:-8}"
  local workdir="${BATS_TEST_TMPDIR}/shellcheck-parallel.$$"
  mkdir -p "$workdir"

  local i
  local active=0
  for ((i = 0; i < count; i++)); do
    {
      shellcheck "${sc_args[@]}" "${files[i]}" \
        > "${workdir}/${i}.out" 2>&1
      printf '%s' "$?" > "${workdir}/${i}.status"
    } &

    active=$((active + 1))
    if ((active >= max_jobs)); then
      # wait -n returns when ANY one bg job completes; throttles the
      # pool to max_jobs concurrent shellchecks. Bash 4.3+ feature;
      # scratch requires 5+.
      wait -n
      active=$((active - 1))
    fi
  done
  wait

  local rc=0
  local file_rc
  for ((i = 0; i < count; i++)); do
    file_rc="$(cat "${workdir}/${i}.status")"
    if [[ "$file_rc" != "0" ]]; then
      rc=1
      printf '\n=== %s (exit %s) ===\n' "${files[i]}" "$file_rc"
      cat "${workdir}/${i}.out"
    fi
  done

  rm -rf "$workdir"
  return "$rc"
}
