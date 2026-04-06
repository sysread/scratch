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
