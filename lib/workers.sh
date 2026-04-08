#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Bounded worker pool primitive
#
# Run N tasks in parallel with a configurable concurrency cap, using a
# FIFO as a counting semaphore. Pre-fill the FIFO with MAX_JOBS tokens;
# each worker reads a token before starting (blocking if the FIFO is
# empty) and writes one back when done. The dispatcher loop never tracks
# PIDs and never calls `wait -n`; the FIFO is the entire concurrency
# mechanism.
#
# This is the lower layer for both shellcheck_parallel (in test/helpers.sh)
# and tool:invoke-parallel (in lib/tool.sh). Both call sites bring their
# own per-task data through parent-shell arrays - bash subshells inherit
# the parent's variables at fork time, so the worker function can index
# into `IDS[i]`, `NAMES[i]`, etc. without any marshalling through env
# vars or files.
#
# Per-task exit codes and output are NOT captured by this primitive;
# that's the worker's responsibility. Both consumers already capture
# stdout, stderr, and exit codes to per-index side files in their own
# workdir, so propagating them through the helper would be wasted work.
#-------------------------------------------------------------------------------

[[ "${_INCLUDED_WORKERS:-}" == "1" ]] && return 0
_INCLUDED_WORKERS=1

_WORKERS_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR/lib
# shellcheck disable=SC1091
source "$_WORKERS_SCRIPTDIR/base.sh"

#-------------------------------------------------------------------------------
# workers:cpu-count
#
# Print the number of online logical CPUs as reported by getconf. Works
# on macOS, all BSDs, and Linux because _NPROCESSORS_ONLN is part of
# POSIX getconf's name space and every Unix we care about supports it.
#
# Falls back to 8 if getconf errors or returns a non-positive value.
# 8 is a sane defensive default for dev workloads.
#-------------------------------------------------------------------------------
workers:cpu-count() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 8)"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || ((n < 1)); then
    n=8
  fi
  printf '%s' "$n"
}

export -f workers:cpu-count

#-------------------------------------------------------------------------------
# workers:run-parallel MAX_JOBS COUNT WORKER_FN
#
# Fork COUNT background jobs, calling WORKER_FN with a single integer
# argument (the task index, 0..COUNT-1), capped at MAX_JOBS concurrent.
# Block until every job has finished, then return 0.
#
# WORKER_FN must be a bash function defined and exported in the parent
# shell. It is responsible for looking up its task data from parent
# variables, doing the work, and writing its output to wherever the
# caller expects to find it (typically per-index files under a workdir
# the caller created and tracked via tmp:make).
#
# This function does not propagate per-task exit codes. WORKER_FN can
# write its own status to a side file; the caller reads them after
# workers:run-parallel returns.
#
# COUNT == 0 returns immediately. MAX_JOBS is silently clamped to a
# minimum of 1.
#
# Implementation notes:
# - The FIFO is created via mktemp -u + mkfifo + immediate unlink so
#   it survives only as long as the open fd. No file system litter
#   even on crash; the OS releases the inode when the fd closes.
# - File descriptor 9 is reserved for the FIFO. Workers do their own
#   work without ever touching fd 9 except to write the return-token,
#   which is also why fd 9 is the high end of the user fd range and
#   unlikely to collide with anything the worker uses.
#-------------------------------------------------------------------------------
workers:run-parallel() {
  local max_jobs="$1"
  local count="$2"
  local worker_fn="$3"

  ((count > 0)) || return 0
  ((max_jobs > 0)) || max_jobs=1

  # FIFO setup. mktemp -u gives us a unique name without creating the
  # file; mkfifo creates the FIFO at that path; the immediate rm
  # unlinks the directory entry while keeping the fd open via exec 9<>.
  local fifo
  fifo="$(mktemp -u -t scratch-workers.XXXXXX)"
  mkfifo "$fifo"
  exec 9<> "$fifo"
  rm -f "$fifo"

  # Prime the semaphore with max_jobs tokens.
  local i
  for ((i = 0; i < max_jobs; i++)); do
    printf '\n' >&9
  done

  # Dispatch loop: read a token (blocks if pool full), fork the worker,
  # worker writes the token back when done.
  for ((i = 0; i < count; i++)); do
    read -r -u 9
    {
      "$worker_fn" "$i"
      printf '\n' >&9
    } &
  done

  wait
  exec 9>&-
  return 0
}

export -f workers:run-parallel