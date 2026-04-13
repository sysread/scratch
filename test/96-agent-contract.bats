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
#   3. pre-fill exists, is +x, has a bash shebang.
#   4. run exists and is +x (if present; run is optional for agents that
#      only use agent:complete).
#   5. is-available exists, is +x, has a bash shebang, AND sources lib/base.sh.
#      Sourcing base.sh is the structural requirement so any has-commands /
#      die / warn calls the script does make actually work. has-commands
#      itself is encouraged but not required - an agent that is pure policy
#      (e.g. just gates on SCRATCH_EDIT_MODE) should not be forced to
#      declare a no-op has-commands line. is-available is also where policy
#      gates live (an agent can refuse to be available outside edit mode, etc.).
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

@test "every agent has pre-fill, executable, with bash shebang" {
  local name
  local dir
  local shebang
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/agents/${name}"

    if [[ ! -f "${dir}/pre-fill" ]]; then
      errs+=("${name}: missing pre-fill")
      continue
    fi

    if [[ ! -x "${dir}/pre-fill" ]]; then
      errs+=("${name}: pre-fill is not executable")
      continue
    fi

    shebang="$(head -n1 "${dir}/pre-fill")"
    case "$shebang" in
      "#!/usr/bin/env bash" | "#!/bin/bash" | "#!/usr/bin/bash") ;;
      *)
        errs+=("${name}: pre-fill must be bash (shebang was: ${shebang})")
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

@test "every agent has run, executable (if present)" {
  local name
  local dir
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/agents/${name}"

    # run is optional - agents that only use agent:complete don't need it
    [[ -f "${dir}/run" ]] || continue

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

@test "every agent's is-available sources lib/base.sh" {
  # is-available must source base.sh so any has-commands / die / warn
  # calls the script does make actually work. has-commands itself is
  # NOT required - a pure-policy agent (e.g. one that gates on
  # SCRATCH_EDIT_MODE without invoking any external binaries) should
  # not be forced to declare a no-op line just to satisfy this test.
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
      errs+=("${name}: is-available must source lib/base.sh (so has-commands / die / warn work at runtime)")
    fi
  done < <(_each_agent)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}
