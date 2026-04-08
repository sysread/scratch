#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tool contract self-reflection
#
# Walks every directory under tools/ and verifies the structural rules
# every tool must follow:
#
#   1. spec.json exists, parses as JSON, has the required fields, and the
#      .name field matches the directory basename.
#   2. .name follows the [a-z][a-z0-9_-]* convention (matches OpenAI's
#      function name rules and shell-safe identifiers).
#   3. main exists, is a regular file, is +x.
#   4. is-available exists, is +x, has a bash shebang, AND sources lib/base.sh.
#      Sourcing base.sh is the structural requirement so any has-commands /
#      die / warn calls the script does make actually work. has-commands
#      itself is encouraged but not required - a tool with no external deps
#      should not be forced to declare a no-op has-commands line just to
#      satisfy a structural test. Author trust > ceremony.
#
# A tool that fails any of these checks is reported with the specific
# violation, all violations collected before failing so authors fix
# everything in one pass.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
}

# Iterate every direct subdirectory of tools/. If tools/ doesn't exist or
# is empty, return without doing anything (test passes vacuously).
_each_tool() {
  local tools_dir="${SCRATCH_HOME}/tools"
  [[ -d "$tools_dir" ]] || return 0

  local d
  for d in "$tools_dir"/*/; do
    [[ -d "$d" ]] || continue
    printf '%s\n' "$(basename "$d")"
  done
}

@test "every tool has spec.json that parses and has required fields" {
  local name
  local dir
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/tools/${name}"

    if [[ ! -f "${dir}/spec.json" ]]; then
      errs+=("${name}: missing spec.json")
      continue
    fi

    if ! jq -e . "${dir}/spec.json" > /dev/null 2>&1; then
      errs+=("${name}: spec.json does not parse as JSON")
      continue
    fi

    local has_name has_desc has_params_type has_params_props has_required
    has_name="$(jq -r '.name // empty' "${dir}/spec.json")"
    has_desc="$(jq -r '.description // empty' "${dir}/spec.json")"
    has_params_type="$(jq -r '.parameters.type // empty' "${dir}/spec.json")"
    has_params_props="$(jq -r '.parameters.properties // empty' "${dir}/spec.json")"
    has_required="$(jq -r '.parameters.required | type' "${dir}/spec.json" 2> /dev/null || echo "")"

    [[ -n "$has_name" ]] || errs+=("${name}: spec.json missing .name")
    [[ -n "$has_desc" ]] || errs+=("${name}: spec.json missing .description")
    [[ "$has_params_type" == "object" ]] || errs+=("${name}: spec.json .parameters.type must be 'object'")
    [[ -n "$has_params_props" ]] || errs+=("${name}: spec.json missing .parameters.properties")
    [[ "$has_required" == "array" ]] || errs+=("${name}: spec.json .parameters.required must be an array")
  done < <(_each_tool)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every tool spec.json .name matches its directory basename" {
  local name
  local dir
  local spec_name
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/tools/${name}"
    [[ -f "${dir}/spec.json" ]] || continue

    spec_name="$(jq -r '.name // empty' "${dir}/spec.json")"
    if [[ "$spec_name" != "$name" ]]; then
      errs+=("${name}: spec.json .name='${spec_name}' does not match directory basename")
    fi
  done < <(_each_tool)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every tool name follows [a-z][a-z0-9_-]* convention" {
  local name
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ ! "$name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
      errs+=("${name}: invalid name (must match ^[a-z][a-z0-9_-]*$)")
    fi
  done < <(_each_tool)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every tool has main, executable" {
  local name
  local dir
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/tools/${name}"

    if [[ ! -f "${dir}/main" ]]; then
      errs+=("${name}: missing main")
      continue
    fi

    if [[ ! -x "${dir}/main" ]]; then
      errs+=("${name}: main is not executable")
    fi
  done < <(_each_tool)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every tool has is-available, executable, with bash shebang" {
  local name
  local dir
  local shebang
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/tools/${name}"

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
  done < <(_each_tool)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every tool's is-available sources lib/base.sh" {
  # is-available must source base.sh so any has-commands / die / warn
  # calls the script does make actually work. has-commands itself is
  # NOT required - a tool with no external deps should not be forced
  # to declare a no-op line just to satisfy this test.
  local name
  local dir
  local file
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/tools/${name}"
    file="${dir}/is-available"
    [[ -f "$file" ]] || continue

    if ! grep -qE 'source[[:space:]].*lib/base\.sh' "$file"; then
      errs+=("${name}: is-available must source lib/base.sh (so has-commands / die / warn work at runtime)")
    fi
  done < <(_each_tool)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}
