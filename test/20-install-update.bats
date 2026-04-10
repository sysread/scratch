#!/usr/bin/env bats

# vim: set ft=bash
set -euo pipefail

#-------------------------------------------------------------------------------
# Integration tests for install.sh, scratch-update, and scratch-uninstall
#
# All network calls are stubbed via a curl shim that serves local files.
# All paths are redirected to temp directories. No real installation,
# network access, or system modification occurs.
#-------------------------------------------------------------------------------

setup() {
  SCRIPTDIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" > /dev/null 2>&1 && pwd)"
  SCRATCH_HOME="$(cd "${SCRIPTDIR}/.." && pwd)"
  source "${SCRIPTDIR}/helpers.sh"

  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  # Redirect install.sh to temp directories
  FAKE_INSTALL_DIR="${BATS_TEST_TMPDIR}/install"
  FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/bin"
  export SCRATCH_INSTALL_DIR="$FAKE_INSTALL_DIR"
  export SCRATCH_INSTALL_BIN_DIR="$FAKE_BIN_DIR"
  export SCRATCH_INSTALL_SKIP_SETUP=1
  export SCRATCH_INSTALL_SKIP_PATH_CHECK=1

  # Build a fake release tarball from the real repo. Includes just enough
  # structure to pass validation (bin/scratch, lib/base.sh, VERSION).
  FAKE_TARBALL="${BATS_TEST_TMPDIR}/scratch-1.0.0.tar.gz"
  _build_fake_tarball "1.0.0" "$FAKE_TARBALL"

  # Stub curl to serve local files based on the URL requested
  _stub_curl
  prepend_stub_path
}

#-------------------------------------------------------------------------------
# Build a minimal tarball that looks like a scratch release
#-------------------------------------------------------------------------------
_build_fake_tarball() {
  local version="$1"
  local output="$2"
  local srcdir="${BATS_TEST_TMPDIR}/tarball-src/scratch-${version}"

  mkdir -p "$srcdir/bin" "$srcdir/lib" "$srcdir/helpers"
  printf '#!/usr/bin/env bash\necho "scratch %s"\n' "$version" > "$srcdir/bin/scratch"
  chmod +x "$srcdir/bin/scratch"
  printf '# base.sh stub\n' > "$srcdir/lib/base.sh"
  printf '%s\n' "$version" > "$srcdir/VERSION"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$srcdir/helpers/setup"
  chmod +x "$srcdir/helpers/setup"

  tar czf "$output" -C "${BATS_TEST_TMPDIR}/tarball-src" "scratch-${version}"
  rm -rf "${BATS_TEST_TMPDIR}/tarball-src"
}

#-------------------------------------------------------------------------------
# Curl stub that routes requests to local files
#
# Recognizes two URL patterns:
#   */VERSION         → serves the version string
#   *.tar.gz          → serves the fake tarball
# Everything else fails.
#-------------------------------------------------------------------------------
_stub_curl() {
  local version_file="${BATS_TEST_TMPDIR}/remote-version"
  printf '1.0.0\n' > "$version_file"

  make_stub curl "$(
    cat << STUB
#!/usr/bin/env bash
# Parse the URL (last non-flag argument)
url=""
outfile=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) outfile="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done

case "\$url" in
  *VERSION*)
    cat "${version_file}"
    ;;
  *.tar.gz*)
    if [[ -n "\$outfile" ]]; then
      cp "${FAKE_TARBALL}" "\$outfile"
    else
      cat "${FAKE_TARBALL}"
    fi
    ;;
  *)
    echo "curl stub: unknown URL: \$url" >&2
    exit 1
    ;;
esac
STUB
  )"
}

# ---------------------------------------------------------------------------
# install.sh
# ---------------------------------------------------------------------------

@test "install.sh creates installation directory and symlink" {
  run bash "${SCRATCH_HOME}/install.sh"
  is "$status" 0

  [[ -d "$FAKE_INSTALL_DIR" ]]
  [[ -L "$FAKE_BIN_DIR/scratch" ]]
  [[ -f "$FAKE_INSTALL_DIR/VERSION" ]]
  [[ "$(cat "$FAKE_INSTALL_DIR/VERSION")" == "1.0.0" ]]
}

@test "install.sh aborts if already installed" {
  mkdir -p "$FAKE_INSTALL_DIR"

  run bash "${SCRATCH_HOME}/install.sh"
  is "$status" 1
  [[ "$output" == *"already installed"* ]]
}

@test "install.sh unpacks tarball with correct structure" {
  run bash "${SCRATCH_HOME}/install.sh"
  is "$status" 0

  [[ -f "$FAKE_INSTALL_DIR/bin/scratch" ]]
  [[ -f "$FAKE_INSTALL_DIR/lib/base.sh" ]]
  [[ -x "$FAKE_INSTALL_DIR/bin/scratch" ]]
}

@test "install.sh symlink points to bin/scratch inside install dir" {
  run bash "${SCRATCH_HOME}/install.sh"
  is "$status" 0

  local target
  target="$(readlink "$FAKE_BIN_DIR/scratch")"
  is "$target" "$FAKE_INSTALL_DIR/bin/scratch"
}

# ---------------------------------------------------------------------------
# release:hat-swap (end-to-end with realistic directory structure)
# ---------------------------------------------------------------------------

@test "hat-swap preserves file permissions" {
  source "${SCRATCH_HOME}/lib/release.sh"

  local install_dir="${BATS_TEST_TMPDIR}/swap-install"
  local new_dir="${BATS_TEST_TMPDIR}/swap-new"

  mkdir -p "$install_dir/bin"
  echo "old" > "$install_dir/bin/scratch"
  chmod +x "$install_dir/bin/scratch"

  mkdir -p "$new_dir/bin"
  echo "new" > "$new_dir/bin/scratch"
  chmod +x "$new_dir/bin/scratch"

  run release:hat-swap "$new_dir" "$install_dir"
  is "$status" 0

  [[ -x "$install_dir/bin/scratch" ]]
  [[ "$(cat "$install_dir/bin/scratch")" == "new" ]]
}

@test "hat-swap leaves symlinks functional after swap" {
  source "${SCRATCH_HOME}/lib/release.sh"

  local install_dir="${BATS_TEST_TMPDIR}/swap-install"
  local new_dir="${BATS_TEST_TMPDIR}/swap-new"
  local symlink="${BATS_TEST_TMPDIR}/swap-bin/scratch"

  mkdir -p "$install_dir/bin"
  echo "old" > "$install_dir/bin/scratch"

  mkdir -p "$(dirname "$symlink")"
  ln -sf "$install_dir/bin/scratch" "$symlink"

  mkdir -p "$new_dir/bin"
  echo "new" > "$new_dir/bin/scratch"

  release:hat-swap "$new_dir" "$install_dir"

  # Symlink still resolves and points to new content
  [[ -L "$symlink" ]]
  [[ "$(cat "$symlink")" == "new" ]]
}

# ---------------------------------------------------------------------------
# scratch-uninstall (non-interactive with --yes)
# ---------------------------------------------------------------------------

@test "scratch-uninstall --yes removes install dir and symlink" {
  # Set up a fake installation
  local fake_home="${BATS_TEST_TMPDIR}/uninstall-home"
  mkdir -p "$fake_home/.local/share/scratch/bin" "$fake_home/.local/bin"

  # Create a minimal scratch-uninstall that can run
  cp "${SCRATCH_HOME}/bin/scratch-uninstall" "$fake_home/.local/share/scratch/bin/"
  cp "${SCRATCH_HOME}/bin/scratch" "$fake_home/.local/share/scratch/bin/"
  cp -r "${SCRATCH_HOME}/lib" "$fake_home/.local/share/scratch/"

  # Create the symlink
  ln -sf "$fake_home/.local/share/scratch/bin/scratch" "$fake_home/.local/bin/scratch"

  # Stub gum so tui.sh doesn't fail at source time
  make_stub gum '#!/usr/bin/env bash
exit 0'
  prepend_stub_path

  run env \
    HOME="$fake_home" \
    PATH="${BATS_TEST_TMPDIR}/stubbin:${SCRATCH_HOME}/bin:$PATH" \
    bash "$fake_home/.local/share/scratch/bin/scratch-uninstall" --yes

  is "$status" 0
  [[ ! -d "$fake_home/.local/share/scratch" ]]
  [[ ! -L "$fake_home/.local/bin/scratch" ]]
}

@test "scratch-uninstall --yes removes config dir when present" {
  local fake_home="${BATS_TEST_TMPDIR}/uninstall-home2"
  mkdir -p "$fake_home/.local/share/scratch/bin" "$fake_home/.local/bin"
  mkdir -p "$fake_home/.config/scratch/projects/test"

  cp "${SCRATCH_HOME}/bin/scratch-uninstall" "$fake_home/.local/share/scratch/bin/"
  cp "${SCRATCH_HOME}/bin/scratch" "$fake_home/.local/share/scratch/bin/"
  cp -r "${SCRATCH_HOME}/lib" "$fake_home/.local/share/scratch/"

  make_stub gum '#!/usr/bin/env bash
exit 0'
  prepend_stub_path

  run env \
    HOME="$fake_home" \
    PATH="${BATS_TEST_TMPDIR}/stubbin:${SCRATCH_HOME}/bin:$PATH" \
    bash "$fake_home/.local/share/scratch/bin/scratch-uninstall" --yes

  is "$status" 0
  [[ ! -d "$fake_home/.config/scratch" ]]
}
