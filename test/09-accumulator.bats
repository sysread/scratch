#!/usr/bin/env bats

# vim: set ft=bash
# shellcheck disable=SC2016
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/accumulator.sh - text-handling layer
#
# Covers the four private text helpers:
#   _accumulate:_token-count
#   _accumulate:_max-chars
#   _accumulate:_split
#   _accumulate:_inject-line-numbers
#
# The chat-layer wrappers (process-chunk, finalize, the reduce loop, and
# the public accumulate:run / accumulate:run-profile entry points) land
# in a follow-up commit and get their own tests.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/accumulator.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# ---------------------------------------------------------------------------
# _accumulate:_token-count
# ---------------------------------------------------------------------------

@test "_accumulate:_token-count: literal string with default 4.0 ratio" {
  # 16 chars / 4 = 4 tokens
  run _accumulate:_token-count "sixteen chars!!!" 4.0
  is "$status" 0
  is "$output" "4"
}

@test "_accumulate:_token-count: literal string with denser 3.0 ratio" {
  # 12 chars / 3 = 4 tokens
  run _accumulate:_token-count "twelve chars" 3.0
  is "$output" "4"
}

@test "_accumulate:_token-count: 1-char input rounds up to 1 token" {
  run _accumulate:_token-count "x" 4.0
  is "$output" "1"
}

@test "_accumulate:_token-count: empty string is 0 tokens" {
  run _accumulate:_token-count "" 4.0
  is "$output" "0"
}

@test "_accumulate:_token-count: reads char count from a file path" {
  printf 'eight!!!' > "${BATS_TEST_TMPDIR}/in.txt"
  run _accumulate:_token-count "${BATS_TEST_TMPDIR}/in.txt" 4.0
  is "$output" "2"
}

@test "_accumulate:_token-count: empty file is 0 tokens" {
  : > "${BATS_TEST_TMPDIR}/empty.txt"
  run _accumulate:_token-count "${BATS_TEST_TMPDIR}/empty.txt" 4.0
  is "$output" "0"
}

@test "_accumulate:_token-count: ceiling rounds 5 chars / 4 up to 2 tokens" {
  run _accumulate:_token-count "fives" 4.0
  is "$output" "2"
}

# ---------------------------------------------------------------------------
# _accumulate:_max-chars
# ---------------------------------------------------------------------------

@test "_accumulate:_max-chars: typical case 8000 * 4 * 0.7 = 22400" {
  run _accumulate:_max-chars 8000 4.0 0.7
  is "$status" 0
  is "$output" "22400"
}

@test "_accumulate:_max-chars: long-context case 1000000 * 4 * 0.7 = 2800000" {
  run _accumulate:_max-chars 1000000 4.0 0.7
  is "$output" "2800000"
}

@test "_accumulate:_max-chars: floors to int" {
  # 100 * 3.5 * 0.5 = 175 exactly, but try a fractional case
  # 100 * 3.3 * 0.5 = 165.0 - still int
  # Use one that produces a fraction: 100 * 3.5 * 0.33 = 115.5 -> 115
  run _accumulate:_max-chars 100 3.5 0.33
  is "$output" "115"
}

@test "_accumulate:_max-chars: respects denser ratio" {
  # 8000 * 3.0 * 0.7 = 16800
  run _accumulate:_max-chars 8000 3.0 0.7
  is "$output" "16800"
}

# ---------------------------------------------------------------------------
# _accumulate:_split
# ---------------------------------------------------------------------------

@test "_accumulate:_split: input fitting one chunk produces a single 0001 file" {
  printf 'short input\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 1000 "${BATS_TEST_TMPDIR}/out"
  run ls "${BATS_TEST_TMPDIR}/out"
  is "$output" "0001"
  run cat "${BATS_TEST_TMPDIR}/out/0001"
  is "$output" "short input"
}

@test "_accumulate:_split: multi-line input requiring multiple chunks" {
  # Each line is 11 chars + newline = 12 bytes. With max=20 we should
  # get one line per chunk (line 2 would push the chunk to 24 > 20).
  printf 'aaaaaaaaaaa\nbbbbbbbbbbb\nccccccccccc\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 20 "${BATS_TEST_TMPDIR}/out"
  run ls "${BATS_TEST_TMPDIR}/out"
  is "$output" "0001
0002
0003"
  run cat "${BATS_TEST_TMPDIR}/out/0001"
  is "$output" "aaaaaaaaaaa"
  run cat "${BATS_TEST_TMPDIR}/out/0002"
  is "$output" "bbbbbbbbbbb"
  run cat "${BATS_TEST_TMPDIR}/out/0003"
  is "$output" "ccccccccccc"
}

@test "_accumulate:_split: chunk packs multiple lines until budget hits" {
  # Five 5-char lines (6 bytes each with newline). Max=20 fits 3 lines
  # (18 bytes); the 4th would push to 24, so it starts chunk 2.
  printf 'aaaaa\nbbbbb\nccccc\nddddd\neeeee\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 20 "${BATS_TEST_TMPDIR}/out"
  run cat "${BATS_TEST_TMPDIR}/out/0001"
  is "$output" "aaaaa
bbbbb
ccccc"
  run cat "${BATS_TEST_TMPDIR}/out/0002"
  is "$output" "ddddd
eeeee"
}

@test "_accumulate:_split: a single line longer than max gets its own chunk" {
  printf 'short\nthisisaveryverylonglinethatexceedsthebudget\nshort\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 10 "${BATS_TEST_TMPDIR}/out"
  # Expected: chunk 1 = "short", chunk 2 = the long line, chunk 3 = "short"
  run ls "${BATS_TEST_TMPDIR}/out"
  is "$output" "0001
0002
0003"
  run cat "${BATS_TEST_TMPDIR}/out/0002"
  is "$output" "thisisaveryverylonglinethatexceedsthebudget"
}

@test "_accumulate:_split: input not ending in a newline preserves the last line" {
  printf 'first\nsecond' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 1000 "${BATS_TEST_TMPDIR}/out"
  run cat "${BATS_TEST_TMPDIR}/out/0001"
  is "$output" "first
second"
}

@test "_accumulate:_split: empty input produces zero chunk files" {
  : > "${BATS_TEST_TMPDIR}/empty.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/empty.txt" 1000 "${BATS_TEST_TMPDIR}/out"
  run bash -c "ls '${BATS_TEST_TMPDIR}/out' | wc -l | tr -d ' '"
  is "$output" "0"
}

@test "_accumulate:_split: chunk boundaries fall on line endings (no half-lines)" {
  printf 'line1\nline2\nline3\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_split "${BATS_TEST_TMPDIR}/in.txt" 10 "${BATS_TEST_TMPDIR}/out"
  # Each chunk file should end with a newline. Use od on the last byte
  # because bash command substitution strips trailing newlines from
  # $(tail -c 1) output.
  for f in "${BATS_TEST_TMPDIR}/out"/*; do
    local last
    last="$(tail -c 1 "$f" | od -An -c | tr -d ' ')"
    is "$last" '\n'
  done
}

# ---------------------------------------------------------------------------
# _accumulate:_inject-line-numbers
# ---------------------------------------------------------------------------

@test "_accumulate:_inject-line-numbers: prefixes every line with <n>:<hash>|" {
  printf 'first line\nsecond line\nthird line\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_inject-line-numbers "${BATS_TEST_TMPDIR}/in.txt" "${BATS_TEST_TMPDIR}/out.txt"

  run cat "${BATS_TEST_TMPDIR}/out.txt"
  # Three lines, each matching <num>:<8 hex>|<original>
  local line1 line2 line3
  line1="$(sed -n '1p' "${BATS_TEST_TMPDIR}/out.txt")"
  line2="$(sed -n '2p' "${BATS_TEST_TMPDIR}/out.txt")"
  line3="$(sed -n '3p' "${BATS_TEST_TMPDIR}/out.txt")"

  [[ "$line1" =~ ^1:[0-9a-f]{8}\|first\ line$ ]]
  [[ "$line2" =~ ^2:[0-9a-f]{8}\|second\ line$ ]]
  [[ "$line3" =~ ^3:[0-9a-f]{8}\|third\ line$ ]]
}

@test "_accumulate:_inject-line-numbers: numbers are 1-based and sequential" {
  printf 'a\nb\nc\nd\ne\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_inject-line-numbers "${BATS_TEST_TMPDIR}/in.txt" "${BATS_TEST_TMPDIR}/out.txt"

  run bash -c "cut -d: -f1 '${BATS_TEST_TMPDIR}/out.txt'"
  is "$output" "1
2
3
4
5"
}

@test "_accumulate:_inject-line-numbers: hashes differ across distinct content" {
  printf 'apple\nbanana\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_inject-line-numbers "${BATS_TEST_TMPDIR}/in.txt" "${BATS_TEST_TMPDIR}/out.txt"

  local h1 h2
  h1="$(sed -n '1p' "${BATS_TEST_TMPDIR}/out.txt" | cut -d: -f2 | cut -d'|' -f1)"
  h2="$(sed -n '2p' "${BATS_TEST_TMPDIR}/out.txt" | cut -d: -f2 | cut -d'|' -f1)"

  [[ "$h1" != "$h2" ]]
}

@test "_accumulate:_inject-line-numbers: identical content gets identical hash" {
  printf 'same\nsame\n' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_inject-line-numbers "${BATS_TEST_TMPDIR}/in.txt" "${BATS_TEST_TMPDIR}/out.txt"

  local h1 h2
  h1="$(sed -n '1p' "${BATS_TEST_TMPDIR}/out.txt" | cut -d: -f2 | cut -d'|' -f1)"
  h2="$(sed -n '2p' "${BATS_TEST_TMPDIR}/out.txt" | cut -d: -f2 | cut -d'|' -f1)"

  is "$h1" "$h2"
}

@test "_accumulate:_inject-line-numbers: handles input not ending in a newline" {
  printf 'first\nlast' > "${BATS_TEST_TMPDIR}/in.txt"
  _accumulate:_inject-line-numbers "${BATS_TEST_TMPDIR}/in.txt" "${BATS_TEST_TMPDIR}/out.txt"

  # Both lines should be present in the output
  run bash -c "wc -l < '${BATS_TEST_TMPDIR}/out.txt' | tr -d ' '"
  is "$output" "2"

  local last
  last="$(sed -n '2p' "${BATS_TEST_TMPDIR}/out.txt")"
  [[ "$last" =~ ^2:[0-9a-f]{8}\|last$ ]]
}
