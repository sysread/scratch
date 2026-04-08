#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Toolbox contract self-reflection
#
# Walks every directory under toolboxes/ and verifies the structural rules
# every toolbox must follow:
#
#   1. tools.json exists, parses as JSON, has the required fields:
#        .description (string)
#        .tools       (array)
#   2. Naming follows the [a-z][a-z0-9_-]* convention.
#   3. is-available exists, is +x, has a bash shebang, AND sources lib/base.sh.
#      Same relaxed contract as tools/agents: has-commands is encouraged
#      when there are real deps but not required for pure-policy gates.
#   4. Every name in .tools references an existing tool (via tool:exists).
#      Catches typos in tools.json that would otherwise be silent until
#      the toolbox actually got used.
#
# Mirror of test/95-tool-contract.bats and test/96-agent-contract.bats.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/tool.sh"
}

# Iterate every direct subdirectory of toolboxes/. If toolboxes/ doesn't
# exist or is empty, return without doing anything (test passes vacuously).
_each_toolbox() {
  local boxes_dir="${SCRATCH_HOME}/toolboxes"
  [[ -d "$boxes_dir" ]] || return 0

  local d
  for d in "$boxes_dir"/*/; do
    [[ -d "$d" ]] || continue
    printf '%s\n' "$(basename "$d")"
  done
}

@test "every toolbox has tools.json that parses and has required fields" {
  local name
  local dir
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/toolboxes/${name}"

    if [[ ! -f "${dir}/tools.json" ]]; then
      errs+=("${name}: missing tools.json")
      continue
    fi

    if ! jq -e . "${dir}/tools.json" > /dev/null 2>&1; then
      errs+=("${name}: tools.json does not parse as JSON")
      continue
    fi

    local desc tools_type
    desc="$(jq -r '.description // empty' "${dir}/tools.json")"
    tools_type="$(jq -r '.tools | type' "${dir}/tools.json" 2> /dev/null || echo "")"

    [[ -n "$desc" ]] || errs+=("${name}: tools.json missing .description")
    [[ "$tools_type" == "array" ]] || errs+=("${name}: tools.json .tools must be an array")
  done < <(_each_toolbox)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every toolbox name follows [a-z][a-z0-9_-]* convention" {
  local name
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ ! "$name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
      errs+=("${name}: invalid name (must match ^[a-z][a-z0-9_-]*$)")
    fi
  done < <(_each_toolbox)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every toolbox has is-available, executable, with bash shebang" {
  local name
  local dir
  local shebang
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/toolboxes/${name}"

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
  done < <(_each_toolbox)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every toolbox's is-available sources lib/base.sh" {
  # is-available must source base.sh so any has-commands / die / warn
  # calls the script does make actually work. has-commands itself is
  # NOT required - most toolboxes are pure policy gates with no
  # external dependencies.
  local name
  local dir
  local file
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/toolboxes/${name}"
    file="${dir}/is-available"
    [[ -f "$file" ]] || continue

    if ! grep -qE 'source[[:space:]].*lib/base\.sh' "$file"; then
      errs+=("${name}: is-available must source lib/base.sh (so has-commands / die / warn work at runtime)")
    fi
  done < <(_each_toolbox)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}

@test "every toolbox's listed tools exist in tools/" {
  # Catches typos in tools.json. Toolboxes/<name>/tools.json that
  # references a tool name with no corresponding directory under
  # tools/ is a bug, not a forward-declaration: the toolbox is broken
  # at runtime because tool:specs-json will die on the unknown name.
  local name
  local dir
  local tool_name
  local -a errs=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="${SCRATCH_HOME}/toolboxes/${name}"
    [[ -f "${dir}/tools.json" ]] || continue

    while IFS= read -r tool_name; do
      [[ -z "$tool_name" ]] && continue
      if ! tool:exists "$tool_name"; then
        errs+=("${name}: tools.json references unknown tool '${tool_name}'")
      fi
    done < <(jq -r '.tools[]' "${dir}/tools.json" 2> /dev/null || true)
  done < <(_each_toolbox)

  if ((${#errs[@]} > 0)); then
    for e in "${errs[@]}"; do
      diag "$e"
    done
    return 1
  fi
}
