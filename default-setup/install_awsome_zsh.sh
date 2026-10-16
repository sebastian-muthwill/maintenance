#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGES=(git python3-pip zsh curl)
APT_SUDO=""

if [[ $EUID -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo must be installed to proceed" >&2
    exit 1
  fi
  APT_SUDO="sudo"
fi

ensure_packages() {
  echo "Updating apt cache..."
  $APT_SUDO apt-get update
  echo "Installing packages: ${PACKAGES[*]}"
  $APT_SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"
}

install_oh_my_zsh() {
  local install_dir="${HOME}/.oh-my-zsh"
  if [[ -d "$install_dir" ]]; then
    echo "oh-my-zsh already installed at $install_dir"
    return
  fi

  echo "Installing oh-my-zsh..."
  RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
}

ensure_plugin() {
  local plugin="$1"
  local plugin_dir="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}/plugins/$plugin"
  if [[ -d "$plugin_dir" ]]; then
    echo "Plugin $plugin already present"
    return
  fi

  echo "Installing plugin $plugin..."
  git clone --depth=1 "https://github.com/zsh-users/${plugin}" "$plugin_dir"
}

write_zshrc() {
  local zshrc="${HOME}/.zshrc"
  local source_zshrc
  source_zshrc="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.zshrc"
  local tmp
  tmp="$(mktemp)"
  trap '[[ -n "${tmp:-}" ]] && rm -f "$tmp"' EXIT

  cp "$source_zshrc" "$tmp"

  if [[ -f "$zshrc" ]]; then
    if cmp -s "$tmp" "$zshrc"; then
      echo ".zshrc already configured"
      return
    fi
    cp "$zshrc" "${zshrc}.bak-$(date +%Y%m%d-%H%M%S)"
  fi

  mv "$tmp" "$zshrc"
  tmp=""
  echo ".zshrc written at $zshrc"
}

main() {
  ensure_packages
  install_oh_my_zsh
  export ZSH_CUSTOM="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"
  ensure_plugin "zsh-autosuggestions"
  write_zshrc

  if [[ "$(command -v chsh)" ]]; then
    echo "Setting zsh as the default shell..."
    if ! chsh -s "$(command -v zsh)"; then
      echo "Failed to change default shell; you may still run 'chsh -s \"$(command -v zsh)\"' manually." >&2
    fi
  else
    echo "chsh is unavailable; run 'chsh -s \"$(command -v zsh)\"' manually to make zsh your login shell."
  fi
}

main