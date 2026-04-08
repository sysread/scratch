#!/usr/bin/env bats

# vim: set ft=bash
# SC2329: every worker_fn here is invoked indirectly via workers:run-parallel
# (which calls it by name through the export -f machinery), not directly.
# shellcheck disable=SC2329
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/workers.sh - bounded worker pool primitive
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." > /dev/null 2>&1 && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/workers.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# ---------------------------------------------------------------------------
# workers:cpu-count
# ---------------------------------------------------------------------------

@test "workers:cpu-count returns a positive integer" {
  run workers:cpu-count
  is "$status" 0
  [[ "$output" =~ ^[0-9]+$ ]]
  ((output > 0))
}

@test "workers:cpu-count falls back to 8 when getconf returns garbage" {
  # Stub getconf to return non-numeric output
  PATH="${BATS_TEST_TMPDIR}/stubbin:${PATH}"
  mkdir -p "${BATS_TEST_TMPDIR}/stubbin"
  cat > "${BATS_TEST_TMPDIR}/stubbin/getconf" << 'EOF'
#!/usr/bin/env bash
echo "not a number"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/stubbin/getconf"

  run workers:cpu-count
  is "$status" 0
  is "$output" "8"
}

@test "workers:cpu-count falls back to 8 when getconf errors" {
  PATH="${BATS_TEST_TMPDIR}/stubbin:${PATH}"
  mkdir -p "${BATS_TEST_TMPDIR}/stubbin"
  cat > "${BATS_TEST_TMPDIR}/stubbin/getconf" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${BATS_TEST_TMPDIR}/stubbin/getconf"

  run workers:cpu-count
  is "$output" "8"
}

# ---------------------------------------------------------------------------
# workers:run-parallel - basic correctness
# ---------------------------------------------------------------------------

@test "workers:run-parallel: COUNT=0 returns immediately and runs nothing" {
  local marker="${BATS_TEST_TMPDIR}/marker"
  : > "$marker"

  worker_fn() { printf 'ran %s\n' "$1" >> "$marker"; }
  export -f worker_fn

  run workers:run-parallel 4 0 worker_fn
  is "$status" 0
  is "$(cat "$marker")" ""
}

@test "workers:run-parallel: runs WORKER_FN exactly COUNT times with correct indices" {
  local outdir="${BATS_TEST_TMPDIR}/out"
  mkdir -p "$outdir"
  export OUTDIR="$outdir"

  worker_fn() { printf '%s' "$1" > "${OUTDIR}/$1"; }
  export -f worker_fn

  workers:run-parallel 4 5 worker_fn

  # Five files numbered 0-4, each containing its own index
  local i
  for i in 0 1 2 3 4; do
    is "$(cat "${outdir}/$i")" "$i"
  done
  # And no extras - count via glob expansion, not ls parsing
  local entries=("$outdir"/*)
  is "${#entries[@]}" "5"
}

@test "workers:run-parallel: respects max_jobs concurrency cap" {
  # Each worker writes "start", sleeps, then writes "end". By tracking
  # the max number of concurrent "start without end" entries we can
  # verify the cap is honored.
  local logfile="${BATS_TEST_TMPDIR}/log"
  : > "$logfile"
  export LOGFILE="$logfile"

  worker_fn() {
    {
      flock 200
      printf 'start %s\n' "$1"
    } 200> "${LOGFILE}.lock"
    sleep 0.2
    {
      flock 200
      printf 'end %s\n' "$1"
    } 200> "${LOGFILE}.lock"
  } >> "$LOGFILE"
  export -f worker_fn

  workers:run-parallel 3 8 worker_fn

  # Walk the log and track max concurrency
  local max_active=0
  local active=0
  while IFS= read -r line; do
    case "$line" in
      start*)
        active=$((active + 1))
        ((active > max_active)) && max_active=$active
        ;;
      end*)
        active=$((active - 1))
        ;;
    esac
  done < "$logfile"

  ((max_active <= 3))
  ((max_active >= 1))
}

@test "workers:run-parallel: max_jobs of 1 serializes execution" {
  local logfile="${BATS_TEST_TMPDIR}/log"
  : > "$logfile"
  export LOGFILE="$logfile"

  worker_fn() {
    {
      flock 200
      printf 'start %s\n' "$1"
    } 200> "${LOGFILE}.lock"
    sleep 0.05
    {
      flock 200
      printf 'end %s\n' "$1"
    } 200> "${LOGFILE}.lock"
  } >> "$LOGFILE"
  export -f worker_fn

  workers:run-parallel 1 4 worker_fn

  # Pairs should be perfectly interleaved: start 0, end 0, start 1, end 1, ...
  local expected
  expected="$(printf 'start 0\nend 0\nstart 1\nend 1\nstart 2\nend 2\nstart 3\nend 3')"
  is "$(cat "$logfile")" "$expected"
}

@test "workers:run-parallel: COUNT smaller than max_jobs runs all in parallel" {
  local outdir="${BATS_TEST_TMPDIR}/out"
  mkdir -p "$outdir"
  export OUTDIR="$outdir"

  worker_fn() { printf 'done %s\n' "$1" > "${OUTDIR}/$1"; }
  export -f worker_fn

  workers:run-parallel 16 3 worker_fn
  local entries=("$outdir"/*)
  is "${#entries[@]}" "3"
}

@test "workers:run-parallel: zero max_jobs is clamped to 1" {
  local outdir="${BATS_TEST_TMPDIR}/out"
  mkdir -p "$outdir"
  export OUTDIR="$outdir"

  worker_fn() { printf '%s' "$1" > "${OUTDIR}/$1"; }
  export -f worker_fn

  workers:run-parallel 0 3 worker_fn
  local entries=("$outdir"/*)
  is "${#entries[@]}" "3"
}

@test "workers:run-parallel: workers can read parent-shell arrays" {
  # The headline use case: each worker indexes into a parent array to
  # find its task data.
  TASKS=("alpha" "beta" "gamma" "delta")
  export TASKS
  local outdir="${BATS_TEST_TMPDIR}/out"
  mkdir -p "$outdir"
  export OUTDIR="$outdir"

  worker_fn() {
    local i="$1"
    printf 'task %s = %s\n' "$i" "${TASKS[i]}" > "${OUTDIR}/$i"
  }
  export -f worker_fn

  workers:run-parallel 2 4 worker_fn

  is "$(cat "${outdir}/0")" "task 0 = alpha"
  is "$(cat "${outdir}/1")" "task 1 = beta"
  is "$(cat "${outdir}/2")" "task 2 = gamma"
  is "$(cat "${outdir}/3")" "task 3 = delta"
}
