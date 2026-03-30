#!/usr/bin/env bash
set -euo pipefail

# Install tnr from Thunder-Compute/thunder-cli GitHub releases.

VERSION=${TNR_VERSION:-}
INSTALL_DIR="${HOME}/.tnr/bin"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
  x86_64|amd64) ARCH=amd64;;
  arm64|aarch64) ARCH=arm64;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1;;
esac

case "$OS" in
  darwin) OS="macos" ;;
esac

# Check for required commands
check_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v tar >/dev/null 2>&1 || missing+=("tar")
  command -v gzip >/dev/null 2>&1 || missing+=("gzip")
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: Missing required commands: ${missing[*]}" >&2
    echo "Please install: ${missing[*]}" >&2
    exit 1
  fi
}

check_deps

# Install jq if missing
ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  
  echo "jq not found. Attempting to install..."
  
  # Check if running as root (use id -u for better compatibility)
  local is_root=false
  if [[ "$(id -u)" -eq 0 ]]; then
    is_root=true
  fi
  
  # Try to detect if we can install packages
  local can_install=false
  local install_cmd=""
  
  if command -v apt-get >/dev/null 2>&1; then
    # Debian/Ubuntu
    if [[ "$is_root" == "true" ]]; then
      can_install=true
      install_cmd="apt-get update -qq && apt-get install -y jq"
    elif sudo -n true 2>/dev/null; then
      can_install=true
      install_cmd="sudo apt-get update -qq && sudo apt-get install -y jq"
    else
      echo "jq is required. Please install it manually:" >&2
      echo "  sudo apt-get update && sudo apt-get install -y jq" >&2
      exit 1
    fi
  elif command -v apk >/dev/null 2>&1; then
    # Alpine
    if [[ "$is_root" == "true" ]]; then
      can_install=true
      install_cmd="apk add --no-cache jq"
    elif sudo -n true 2>/dev/null; then
      can_install=true
      install_cmd="sudo apk add --no-cache jq"
    else
      echo "jq is required. Please install it manually:" >&2
      echo "  sudo apk add --no-cache jq" >&2
      exit 1
    fi
  elif command -v yum >/dev/null 2>&1; then
    # RHEL/CentOS 7
    if [[ "$is_root" == "true" ]]; then
      can_install=true
      install_cmd="yum install -y jq"
    elif sudo -n true 2>/dev/null; then
      can_install=true
      install_cmd="sudo yum install -y jq"
    else
      echo "jq is required. Please install it manually:" >&2
      echo "  sudo yum install -y jq" >&2
      exit 1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    # Fedora/RHEL/CentOS 8+
    if [[ "$is_root" == "true" ]]; then
      can_install=true
      install_cmd="dnf install -y jq"
    elif sudo -n true 2>/dev/null; then
      can_install=true
      install_cmd="sudo dnf install -y jq"
    else
      echo "jq is required. Please install it manually:" >&2
      echo "  sudo dnf install -y jq" >&2
      exit 1
    fi
  fi
  
  if [[ "$can_install" == "true" ]]; then
    echo "Installing jq..."
    if eval "$install_cmd"; then
      if command -v jq >/dev/null 2>&1; then
        echo "✓ jq installed successfully"
        return 0
      fi
    fi
  fi
  
  # If we get here, installation failed or not supported
  echo "Error: jq is required but could not be installed automatically." >&2
  echo "Please install jq manually: https://stedolan.github.io/jq/download/" >&2
  exit 1
}

ensure_jq

GITHUB_REPO="Thunder-Compute/thunder-cli"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "Fetching latest release from GitHub"
release_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
curl -fsSL "$release_url" -o "$tmpdir/release.json"

if [[ -z "$VERSION" ]]; then
  VERSION=$(jq -r '.tag_name' "$tmpdir/release.json" | sed 's/^v//')
fi

asset_name="tnr_${VERSION}_${OS}_${ARCH}.tar.gz"
asset_url=$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$tmpdir/release.json")

if [[ -z "$asset_url" ]]; then
  echo "Error: Could not find asset $asset_name in the latest release" >&2
  exit 1
fi

echo "Downloading $asset_url"
archive="$tmpdir/tnr.tar.gz"
curl -fL "$asset_url" -o "$archive"

checksums_url=$(jq -r --arg name "checksums.txt" '.assets[] | select(.name == $name) | .browser_download_url' "$tmpdir/release.json")
if [[ -n "$checksums_url" ]]; then
  echo "Verifying checksum"
  curl -fsSL "$checksums_url" -o "$tmpdir/checksums.txt"
  sum=$(sha256sum "$archive" | awk '{print $1}')
  grep -q "$sum" "$tmpdir/checksums.txt" || { echo "Checksum mismatch" >&2; exit 1; }
else
  echo "Warning: checksums.txt not found in release, skipping checksum verification"
fi

mkdir -p "$INSTALL_DIR"

echo "Extracting"
tar -xzf "$archive" -C "$tmpdir"

install -m 0755 "$tmpdir/tnr" "$INSTALL_DIR/tnr"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    # Detect shell and pick the right profile file
    PROFILE=""
    PROFILE_FALLBACK="$HOME/.profile"
    
    if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == */zsh ]]; then
      PROFILE="$HOME/.zshrc"
    elif [[ -n "${BASH_VERSION:-}" ]] || [[ "$SHELL" == */bash ]]; then
      PROFILE="$HOME/.bashrc"
      # Support .bash_profile on macOS (default for login shells)
      if [[ -f "$HOME/.bash_profile" ]]; then
        PROFILE="$HOME/.bash_profile"
      fi
    else
      PROFILE="$HOME/.profile"
    fi

    # Function to add PATH to a profile file
    add_to_profile() {
      local file="$1"
      if [[ -w "$(dirname "$file")" ]] && ! grep -q '.tnr/bin' "$file" 2>/dev/null; then
        echo "" >> "$file"
        echo '# Added by tnr installer' >> "$file"
        echo 'export PATH="$HOME/.tnr/bin:$PATH"' >> "$file"
        return 0
      fi
      return 1
    }

    # Add to primary profile
    ADDED_TO=""
    if [[ -n "$PROFILE" ]] && add_to_profile "$PROFILE"; then
      ADDED_TO="$PROFILE"
    fi

    # Also add to .profile for /bin/sh compatibility (unless it's already the primary)
    if [[ "$PROFILE" != "$PROFILE_FALLBACK" ]] && add_to_profile "$PROFILE_FALLBACK"; then
      if [[ -z "$ADDED_TO" ]]; then
        ADDED_TO="$PROFILE_FALLBACK"
      else
        ADDED_TO="$ADDED_TO and $PROFILE_FALLBACK"
      fi
    fi

    if [[ -n "$ADDED_TO" ]]; then
      echo "✓ Added $INSTALL_DIR to PATH in $ADDED_TO"
      echo "  Run '. $PROFILE' or 'source $PROFILE' or restart your terminal to use tnr"
    else
      echo ""
      echo "Could not write to shell profile. Add $INSTALL_DIR to your PATH manually:"
      echo "  export PATH=\"\$HOME/.tnr/bin:\$PATH\""
    fi
    ;;
esac

echo "✓ Installed tnr $VERSION to $INSTALL_DIR"


