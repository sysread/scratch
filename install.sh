#!/usr/bin/env bash

#-------------------------------------------------------------------------------
# Standalone installer for scratch
#
# Downloads the latest release from GitHub, unpacks it to ~/.local/share/scratch,
# and creates a symlink in ~/.local/bin. No dependencies on scratch's own
# libraries — this runs before scratch exists on the system.
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/sysread/scratch/main/install.sh)"
#-------------------------------------------------------------------------------

set -euo pipefail

#-------------------------------------------------------------------------------
# Constants — overridable via env vars for testing
#-------------------------------------------------------------------------------
REPO="${SCRATCH_INSTALL_REPO:-sysread/scratch}"
INSTALL_DIR="${SCRATCH_INSTALL_DIR:-$HOME/.local/share/scratch}"
BIN_DIR="${SCRATCH_INSTALL_BIN_DIR:-$HOME/.local/bin}"
SYMLINK="$BIN_DIR/scratch"
VERSION_URL="${SCRATCH_INSTALL_VERSION_URL:-https://raw.githubusercontent.com/$REPO/main/VERSION}"
SKIP_SETUP="${SCRATCH_INSTALL_SKIP_SETUP:-}"
SKIP_PATH_CHECK="${SCRATCH_INSTALL_SKIP_PATH_CHECK:-}"

#-------------------------------------------------------------------------------
# Pre-flight checks
#-------------------------------------------------------------------------------
if [[ -d "$INSTALL_DIR" ]] || [[ -L "$SYMLINK" ]]; then
  echo "scratch is already installed at $INSTALL_DIR"
  echo "Use 'scratch update' to update to the latest version."
  exit 1
fi

for cmd in curl tar; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "error: $cmd is required but not found" >&2
    exit 1
  fi
done

#-------------------------------------------------------------------------------
# Fetch latest version
#-------------------------------------------------------------------------------
echo "Fetching latest version..."
VERSION="$(curl -fsSL "$VERSION_URL" | tr -d '[:space:]')"

if [[ -z "$VERSION" ]]; then
  echo "error: could not determine latest version" >&2
  exit 1
fi

echo "Latest version: $VERSION"

#-------------------------------------------------------------------------------
# Download and unpack
#-------------------------------------------------------------------------------
TARBALL_URL="${SCRATCH_INSTALL_TARBALL_URL:-https://github.com/$REPO/releases/download/v${VERSION}/scratch-${VERSION}.tar.gz}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading scratch $VERSION..."
if ! curl -fsSL -o "$TMPDIR/scratch.tar.gz" "$TARBALL_URL"; then
  echo "error: failed to download $TARBALL_URL" >&2
  echo "" >&2
  echo "Make sure version $VERSION has been released." >&2
  echo "Check: https://github.com/$REPO/releases" >&2
  exit 1
fi

echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
tar xzf "$TMPDIR/scratch.tar.gz" -C "$INSTALL_DIR" --strip-components=1

#-------------------------------------------------------------------------------
# Create symlink
#-------------------------------------------------------------------------------
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/scratch" "$SYMLINK"
echo "Linked $SYMLINK -> $INSTALL_DIR/bin/scratch"

#-------------------------------------------------------------------------------
# PATH check and shell rc setup
#
# If ~/.local/bin is already on PATH, nothing to do. Otherwise, detect the
# user's shell and offer to append the PATH line to the appropriate rc file.
# Handles bash, zsh, and fish. Unknown shells get manual instructions.
#-------------------------------------------------------------------------------
_setup_path() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) return 0 ;;
  esac

  echo ""
  echo "$BIN_DIR is not on your PATH."

  local shell_name rc_file
  shell_name="$(basename "${SHELL:-/bin/bash}")"

  case "$shell_name" in
    bash)
      if [[ -f "$HOME/.bashrc" ]]; then
        rc_file="$HOME/.bashrc"
      elif [[ -f "$HOME/.bash_profile" ]]; then
        rc_file="$HOME/.bash_profile"
      else
        rc_file="$HOME/.bashrc"
      fi
      ;;
    zsh)
      rc_file="$HOME/.zshrc"
      ;;
    fish)
      rc_file="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
      ;;
    *)
      echo "Add $BIN_DIR to your PATH manually."
      return 0
      ;;
  esac

  printf 'Add %s to PATH in %s? [y/N] ' "$BIN_DIR" "$rc_file"
  local answer
  read -r answer

  case "$answer" in
    [yY]*)
      if [[ "$shell_name" == "fish" ]]; then
        mkdir -p "$(dirname "$rc_file")"
        printf '\nfish_add_path %s\n' "$BIN_DIR" >> "$rc_file"
      else
        printf '\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$rc_file"
      fi
      echo "Added to $rc_file. Restart your shell or run: source $rc_file"
      ;;
    *)
      echo ""
      echo "Add it manually:"
      if [[ "$shell_name" == "fish" ]]; then
        echo "  fish_add_path $BIN_DIR"
      else
        echo "  export PATH=\"$BIN_DIR:\$PATH\""
      fi
      ;;
  esac
}

[[ -n "$SKIP_PATH_CHECK" ]] || _setup_path

#-------------------------------------------------------------------------------
# Install runtime dependencies
#-------------------------------------------------------------------------------
if [[ -z "$SKIP_SETUP" ]]; then
  echo ""
  echo "Installing runtime dependencies..."
  if ! "$INSTALL_DIR/helpers/setup"; then
    echo ""
    echo "Some dependencies could not be installed automatically."
    echo "Run 'scratch doctor' after fixing your environment."
  fi
fi

#-------------------------------------------------------------------------------
# Done
#-------------------------------------------------------------------------------
echo ""
echo "scratch $VERSION installed successfully!"
echo "Run 'scratch help' to get started."
