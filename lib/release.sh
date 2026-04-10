#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Release utilities - version checking, tarball management, and hat-swap updates
#
# Pure mechanics layer: no TUI, no user interaction. Callers (scratch-version,
# scratch-update, install.sh) own the UX. This keeps the library testable and
# reusable without pulling in gum or tui.sh.
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Prevent multiple inclusions
#-------------------------------------------------------------------------------
[[ "${_INCLUDED_RELEASE:-}" == "1" ]] && return 0
_INCLUDED_RELEASE=1

#-------------------------------------------------------------------------------
# Imports
#-------------------------------------------------------------------------------
_RELEASE_SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC1091
{
  source "$_RELEASE_SCRIPTDIR/base.sh"
}

has-commands curl tar

#-------------------------------------------------------------------------------
# Constants — overridable via env vars for testing
#-------------------------------------------------------------------------------
_RELEASE_REPO="${SCRATCH_RELEASE_REPO:-sysread/scratch}"
_RELEASE_RAW_URL="${SCRATCH_RELEASE_VERSION_URL:-https://raw.githubusercontent.com/$_RELEASE_REPO/main/VERSION}"

#-------------------------------------------------------------------------------
# release:local-version
#
# Print the installed version from $SCRATCH_HOME/VERSION. Returns 1 if the
# file is missing or empty.
#-------------------------------------------------------------------------------
release:local-version() {
  local version_file="${SCRATCH_HOME:?SCRATCH_HOME not set}/VERSION"

  if [[ ! -f "$version_file" ]]; then
    warn "VERSION file not found: $version_file"
    return 1
  fi

  local version
  version="$(tr -d '[:space:]' < "$version_file")"

  if [[ -z "$version" ]]; then
    warn "VERSION file is empty: $version_file"
    return 1
  fi

  printf '%s' "$version"
}

#-------------------------------------------------------------------------------
# release:remote-version
#
# Fetch and print the latest version from the main branch on GitHub.
# Returns 1 on network error.
#-------------------------------------------------------------------------------
release:remote-version() {
  local version
  version="$(curl -fsSL "$_RELEASE_RAW_URL" 2> /dev/null | tr -d '[:space:]')"

  if [[ -z "$version" ]]; then
    warn "could not fetch remote version"
    return 1
  fi

  printf '%s' "$version"
}

#-------------------------------------------------------------------------------
# release:is-newer VERSION_A VERSION_B
#
# Returns 0 if VERSION_A is strictly newer than VERSION_B. Both must be
# dotted semver triples (e.g., 1.2.3). Comparison is numeric per component:
# major, then minor, then patch.
#-------------------------------------------------------------------------------
release:is-newer() {
  local a="$1" b="$2"

  local a_major a_minor a_patch
  IFS='.' read -r a_major a_minor a_patch <<< "$a"

  local b_major b_minor b_patch
  IFS='.' read -r b_major b_minor b_patch <<< "$b"

  if ((a_major > b_major)); then
    return 0
  elif ((a_major == b_major)); then
    if ((a_minor > b_minor)); then
      return 0
    elif ((a_minor == b_minor)); then
      if ((a_patch > b_patch)); then
        return 0
      fi
    fi
  fi

  return 1
}

#-------------------------------------------------------------------------------
# release:tarball-url VERSION
#
# Print the GitHub release download URL for the given version's tarball.
#-------------------------------------------------------------------------------
release:tarball-url() {
  local version="$1"
  printf 'https://github.com/%s/releases/download/v%s/scratch-%s.tar.gz' \
    "$_RELEASE_REPO" "$version" "$version"
}

#-------------------------------------------------------------------------------
# release:download VERSION DEST_DIR
#
# Download the release tarball for VERSION into DEST_DIR. The file is named
# scratch-VERSION.tar.gz. Returns 1 on failure.
#-------------------------------------------------------------------------------
release:download() {
  local version="$1"
  local dest_dir="$2"
  local url tarball

  url="$(release:tarball-url "$version")"
  tarball="$dest_dir/scratch-${version}.tar.gz"

  if ! curl -fsSL -o "$tarball" "$url"; then
    warn "failed to download $url"
    return 1
  fi

  printf '%s' "$tarball"
}

#-------------------------------------------------------------------------------
# release:unpack TARBALL DEST_DIR
#
# Unpack a release tarball into DEST_DIR, stripping the top-level
# scratch-VERSION/ prefix so contents land directly in DEST_DIR.
# Creates DEST_DIR if it doesn't exist. Returns 1 on failure.
#-------------------------------------------------------------------------------
release:unpack() {
  local tarball="$1"
  local dest_dir="$2"

  mkdir -p "$dest_dir"

  if ! tar xzf "$tarball" -C "$dest_dir" --strip-components=1; then
    warn "failed to unpack $tarball"
    return 1
  fi
}

#-------------------------------------------------------------------------------
# release:hat-swap NEW_DIR INSTALL_DIR
#
# Replace INSTALL_DIR with NEW_DIR using the Indiana Jones hat swap:
#
#   1. mv INSTALL_DIR → INSTALL_DIR.old
#   2. mv NEW_DIR → INSTALL_DIR
#   3. rm -rf INSTALL_DIR.old
#
# If step 2 fails, INSTALL_DIR.old is restored. Step 3 failure is non-fatal
# (stale copy warning). Returns 1 on unrecoverable failure.
#
# Both directories should be on the same filesystem for atomic renames.
#-------------------------------------------------------------------------------
release:hat-swap() {
  local new_dir="$1"
  local install_dir="$2"
  local old_dir="${install_dir}.old"

  # Step 1: move current install aside
  if ! mv "$install_dir" "$old_dir"; then
    warn "failed to move $install_dir aside"
    return 1
  fi

  # Step 2: move new version into place
  if ! mv "$new_dir" "$install_dir"; then
    warn "failed to move new version into place — restoring previous install"
    mv "$old_dir" "$install_dir"
    return 1
  fi

  # Step 3: clean up old version (non-fatal)
  if ! rm -rf "$old_dir"; then
    warn "could not remove old install at $old_dir — remove it manually"
  fi
}

#-------------------------------------------------------------------------------
# release:is-git-install
#
# Returns 0 if SCRATCH_HOME looks like a git clone (has a .git directory).
# Used by scratch-update to suggest `git pull` instead of hat-swap.
#-------------------------------------------------------------------------------
release:is-git-install() {
  [[ -d "${SCRATCH_HOME:?SCRATCH_HOME not set}/.git" ]]
}

export -f \
  release:local-version \
  release:remote-version \
  release:is-newer \
  release:tarball-url \
  release:download \
  release:unpack \
  release:hat-swap \
  release:is-git-install
