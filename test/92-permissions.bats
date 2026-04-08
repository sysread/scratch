#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

# Policy:
# - Commands and entrypoints in bin/ must be executable.
# - Helper scripts in helpers/ must be executable.
# - Library files in lib/ and libexec/ must NOT be executable.
# - Static data files in data/ must NOT be executable.
# - Tool main and is-available scripts in tools/<name>/ must be executable.
# - Tool spec.json files must NOT be executable (they're data, not code).

load "./helpers.sh"

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." > /dev/null 2>&1 && pwd)"
}

@test "bin/ and helpers/ scripts are executable" {
  local -a files=()

  while IFS= read -r f; do
    [[ "$f" == *.md ]] && continue
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files bin/ helpers/)

  for f in "${files[@]}"; do
    if [[ ! -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected executable: $f"
      return 1
    fi
  done
}

@test "lib/ files are not executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files lib/)

  for f in "${files[@]}"; do
    if [[ -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected non-executable: $f"
      return 1
    fi
  done
}

@test "libexec/ files are not executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files libexec/)

  [[ ${#files[@]} -eq 0 ]] && return 0

  for f in "${files[@]}"; do
    if [[ -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected non-executable: $f"
      return 1
    fi
  done
}

@test "data/ files are not executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files data/)

  [[ ${#files[@]} -eq 0 ]] && return 0

  for f in "${files[@]}"; do
    if [[ -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected non-executable: $f"
      return 1
    fi
  done
}

@test "tools/<name>/main and is-available are executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files 'tools/*/main' 'tools/*/is-available')

  [[ ${#files[@]} -eq 0 ]] && return 0

  for f in "${files[@]}"; do
    if [[ ! -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected executable: $f"
      return 1
    fi
  done
}

@test "tools/<name>/spec.json files are not executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files 'tools/*/spec.json')

  [[ ${#files[@]} -eq 0 ]] && return 0

  for f in "${files[@]}"; do
    if [[ -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected non-executable: $f"
      return 1
    fi
  done
}

@test "agents/<name>/run and is-available are executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files 'agents/*/run' 'agents/*/is-available')

  [[ ${#files[@]} -eq 0 ]] && return 0

  for f in "${files[@]}"; do
    if [[ ! -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected executable: $f"
      return 1
    fi
  done
}

@test "agents/<name>/spec.json files are not executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files 'agents/*/spec.json')

  [[ ${#files[@]} -eq 0 ]] && return 0

  for f in "${files[@]}"; do
    if [[ -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected non-executable: $f"
      return 1
    fi
  done
}

@test "toolboxes/<name>/is-available is executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files 'toolboxes/*/is-available')

  [[ ${#files[@]} -eq 0 ]] && return 0

  for f in "${files[@]}"; do
    if [[ ! -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected executable: $f"
      return 1
    fi
  done
}

@test "toolboxes/<name>/tools.json files are not executable" {
  local -a files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$SCRATCH_HOME" ls-files 'toolboxes/*/tools.json')

  [[ ${#files[@]} -eq 0 ]] && return 0

  for f in "${files[@]}"; do
    if [[ -x "$SCRATCH_HOME/$f" ]]; then
      echo "expected non-executable: $f"
      return 1
    fi
  done
}
