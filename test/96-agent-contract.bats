#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Agent contract self-reflection
#
# Walks every directory under agents/ and verifies the structural rules
# every agent must follow:
#
#   1. spec.json exists, parses as JSON, has .name and .description fields,
#      and the .name field matches the directory basename.
#   2. .name follows the [a-z][a-z0-9_-]* convention (shell-safe identifiers).
#   3. run exists, is a regular file, is +x.
#   4. is-available exists, is +x, has a bash shebang, AND sources lib/base.sh
#      AND contains at least one has-commands declaration. The dual contract
#      makes is-available do double duty: real runtime gate AND scannable
#      dep manifest for the doctor. is-available is also where policy gates
#      live (an agent can refuse to be available outside edit mode, etc.).
#
# Mirror of test/95-tool-contract.bats. Agents and tools share the
# same is-available contract because the doctor scanner treats both
# the same way.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
}

# Iterate every direct subdirectory of agents/. If agents/ doesn't exist
# or is empty, return without doing anything (test passes vacuously).
_each_agent() {
  local agents_dir="${SCRATCH_HOME}/agents"
  [[ -d "$agents_dir" ]] || return 0

  local d
  for d in "$agents_dir"/*/; do
    [[ -d "$d" ]] || continue
    printf '%s\n' "$(basename "$d")"
  done
}

@test "every agent has spec.json that parses and has required fields" {
  local name
  local dir
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/agents/${name}"

    if [[ ! -f "${dir}/spec.json" ]]; then
      errs+=("${name}: missing spec.json")
      continue
    fi

    if ! jq -e . "${dir}/spec.json" > /dev/null 2>&1; then
      errs+=("${name}: spec.json does not parse as JSON")
      continue
    fi

    local has_name has_desc
    has_name="$(jq -r '.name // empty' "${dir}/spec.json")"
    has_desc="$(jq -r '.description // empty' "${dir}/spec.json")"

    [[ -n "$has_name" ]] || errs+=("${name}: spec.json missing .name")
    [[ -n "$has_desc" ]] || errs+=("${name}: spec.json missing .description")
  done < <(_each_agent)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every agent spec.json .name matches its directory basename" {
  local name
  local dir
  local spec_name
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/agents/${name}"
    [[ -f "${dir}/spec.json" ]] || continue

    spec_name="$(jq -r '.name // empty' "${dir}/spec.json")"
    if [[ "$spec_name" != "$name" ]]; then
      errs+=("${name}: spec.json .name='${spec_name}' does not match directory basename")
    fi
  done < <(_each_agent)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every agent name follows [a-z][a-z0-9_-]* convention" {
  local name
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ ! "$name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
      errs+=("${name}: invalid name (must match ^[a-z][a-z0-9_-]*$)")
    fi
  done < <(_each_agent)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every agent has run, executable" {
  local name
  local dir
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/agents/${name}"

    if [[ ! -f "${dir}/run" ]]; then
      errs+=("${name}: missing run")
      continue
    fi

    if [[ ! -x "${dir}/run" ]]; then
      errs+=("${name}: run is not executable")
    fi
  done < <(_each_agent)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every agent has is-available, executable, with bash shebang" {
  local name
  local dir
  local shebang
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/agents/${name}"

    if [[ ! -f "${dir}/is-available" ]]; then
      errs+=("${name}: missing is-available")
      continue
    fi

    if [[ ! -x "${dir}/is-available" ]]; then
      errs+=("${name}: is-available is not executable")
      continue
    fi

    shebang="$(head -n1 "${dir}/is-available")"
    case "$shebang" in
      "#!/usr/bin/env bash" | "#!/bin/bash" | "#!/usr/bin/bash") ;;
      *)
        errs+=("${name}: is-available must be bash (shebang was: ${shebang})")
        ;;
    esac
  done < <(_each_agent)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every agent's is-available sources lib/base.sh and calls has-commands" {
  # The double-duty contract: is-available must source base.sh AND call
  # has-commands for at least one command. This ensures the script is a
  # real runtime gate (not a dead no-op) AND the doctor's textual scanner
  # has something to discover.
  local name
  local dir
  local file
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/agents/${name}"
    file="${dir}/is-available"
    [[ -f "$file" ]] || continue

    if ! grep -qE 'source[[:space:]].*lib/base\.sh' "$file"; then
      errs+=("${name}: is-available must source lib/base.sh (so has-commands works at runtime)")
    fi

    if ! grep -qE '^[[:space:]]*has-commands[[:space:]]' "$file"; then
      errs+=("${name}: is-available must contain at least one has-commands declaration")
    fi
  done < <(_each_agent)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}
