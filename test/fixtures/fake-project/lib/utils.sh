#!/usr/bin/env bash
# Shared utilities for the fake project.
# Demonstrates a nested file for testing directory traversal.

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

die() {
  log "FATAL: $*"
  exit 1
}

is_number() {
  [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}
