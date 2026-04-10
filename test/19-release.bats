#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Tests for lib/release.sh
#
# Network calls (curl) are stubbed. Hat-swap tests use temporary directories
# to simulate installation swaps.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"
  source "${SCRATCH_HOME}/lib/release.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# ---------------------------------------------------------------------------
# release:local-version
# ---------------------------------------------------------------------------

@test "release:local-version reads VERSION file" {
  export SCRATCH_HOME="${BATS_TEST_TMPDIR}/fake-install"
  mkdir -p "$SCRATCH_HOME"
  printf '1.2.3\n' > "$SCRATCH_HOME/VERSION"

  run release:local-version
  is "$status" 0
  is "$output" "1.2.3"
}

@test "release:local-version strips whitespace" {
  export SCRATCH_HOME="${BATS_TEST_TMPDIR}/fake-install"
  mkdir -p "$SCRATCH_HOME"
  printf '  1.2.3  \n' > "$SCRATCH_HOME/VERSION"

  run release:local-version
  is "$status" 0
  is "$output" "1.2.3"
}

@test "release:local-version returns 1 when file is missing" {
  export SCRATCH_HOME="${BATS_TEST_TMPDIR}/empty"
  mkdir -p "$SCRATCH_HOME"

  run release:local-version
  is "$status" 1
}

@test "release:local-version returns 1 when file is empty" {
  export SCRATCH_HOME="${BATS_TEST_TMPDIR}/fake-install"
  mkdir -p "$SCRATCH_HOME"
  printf '' > "$SCRATCH_HOME/VERSION"

  run release:local-version
  is "$status" 1
}

# ---------------------------------------------------------------------------
# release:is-newer
# ---------------------------------------------------------------------------

@test "release:is-newer returns 0 when A > B (patch)" {
  run release:is-newer "1.2.4" "1.2.3"
  is "$status" 0
}

@test "release:is-newer returns 0 when A > B (minor)" {
  run release:is-newer "1.3.0" "1.2.9"
  is "$status" 0
}

@test "release:is-newer returns 0 when A > B (major)" {
  run release:is-newer "2.0.0" "1.99.99"
  is "$status" 0
}

@test "release:is-newer returns 1 when equal" {
  run release:is-newer "1.2.3" "1.2.3"
  is "$status" 1
}

@test "release:is-newer returns 1 when A < B" {
  run release:is-newer "1.2.3" "1.2.4"
  is "$status" 1
}

@test "release:is-newer returns 1 when A < B (major)" {
  run release:is-newer "1.0.0" "2.0.0"
  is "$status" 1
}

# ---------------------------------------------------------------------------
# release:tarball-url
# ---------------------------------------------------------------------------

@test "release:tarball-url formats the correct URL" {
  run release:tarball-url "1.2.3"
  is "$status" 0
  is "$output" "https://github.com/sysread/scratch/releases/download/v1.2.3/scratch-1.2.3.tar.gz"
}

# ---------------------------------------------------------------------------
# release:hat-swap
# ---------------------------------------------------------------------------

@test "release:hat-swap replaces install dir with new dir" {
  local install_dir="${BATS_TEST_TMPDIR}/install"
  local new_dir="${BATS_TEST_TMPDIR}/new"

  mkdir -p "$install_dir"
  echo "old" > "$install_dir/marker"

  mkdir -p "$new_dir"
  echo "new" > "$new_dir/marker"

  run release:hat-swap "$new_dir" "$install_dir"
  is "$status" 0

  # New content is in place
  [[ "$(cat "$install_dir/marker")" == "new" ]]

  # Old dir is gone
  [[ ! -d "${install_dir}.old" ]]

  # New dir is gone (moved into install_dir)
  [[ ! -d "$new_dir" ]]
}

@test "release:hat-swap restores old on failed move-in" {
  local install_dir="${BATS_TEST_TMPDIR}/install"
  local new_dir="${BATS_TEST_TMPDIR}/nonexistent/deep/path"

  mkdir -p "$install_dir"
  echo "old" > "$install_dir/marker"

  # new_dir doesn't exist, so mv will fail at step 2
  run release:hat-swap "$new_dir" "$install_dir"
  is "$status" 1

  # Old content is restored
  [[ "$(cat "$install_dir/marker")" == "old" ]]
}

# ---------------------------------------------------------------------------
# release:is-git-install
# ---------------------------------------------------------------------------

@test "release:is-git-install returns 0 for git repos" {
  export SCRATCH_HOME="${BATS_TEST_TMPDIR}/git-install"
  mkdir -p "$SCRATCH_HOME/.git"

  run release:is-git-install
  is "$status" 0
}

@test "release:is-git-install returns 1 for tarball installs" {
  export SCRATCH_HOME="${BATS_TEST_TMPDIR}/tarball-install"
  mkdir -p "$SCRATCH_HOME"

  run release:is-git-install
  is "$status" 1
}

# ---------------------------------------------------------------------------
# release:unpack
# ---------------------------------------------------------------------------

@test "release:unpack extracts tarball with strip-components" {
  local dest="${BATS_TEST_TMPDIR}/unpacked"
  local tarball="${BATS_TEST_TMPDIR}/test.tar.gz"

  # Create a tarball with a top-level prefix directory
  local srcdir="${BATS_TEST_TMPDIR}/scratch-1.0.0"
  mkdir -p "$srcdir/bin" "$srcdir/lib"
  echo "entry" > "$srcdir/bin/scratch"
  echo "lib" > "$srcdir/lib/base.sh"
  tar czf "$tarball" -C "${BATS_TEST_TMPDIR}" "scratch-1.0.0"

  run release:unpack "$tarball" "$dest"
  is "$status" 0

  # Files land directly in dest, not under scratch-1.0.0/
  [[ -f "$dest/bin/scratch" ]]
  [[ -f "$dest/lib/base.sh" ]]
}
