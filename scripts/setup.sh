#!/bin/bash
set -euo pipefail

REPO_DIR=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
APT_PACKAGES=(dialog inotify-tools jq libnotify-bin python3-yaml)

print_step() {
    printf '\n\033[1m%s\033[0m\n' "$1"
}

ensure_not_root() {
    [ "$EUID" -ne 0 ] || {
        echo "ERROR: run setup as your normal user; it asks for sudo only for the commands that need it." >&2
        exit 1
    }
}

ensure_proton_cli() {
    command -v proton-drive >/dev/null || {
        cat >&2 <<'MESSAGE'
ERROR: the proton-drive command isn't installed. Install Proton's Drive CLI, then rerun setup:
  1. Download the Linux file from https://proton.me/download/drive/cli/index.html
  2. chmod +x proton-drive && mkdir -p ~/.local/bin && mv proton-drive ~/.local/bin/
  3. proton-drive auth login
MESSAGE
        exit 1
    }
}

run_as_root() {
    echo "sudo needed for: $*"
    sudo -p "[sudo] password for %u: " "$@"
}

install_apt_packages() {
    run_as_root apt-get update -qq
    run_as_root apt-get install -y -qq "${APT_PACKAGES[@]}"
}

create_settings_from_example() {
    if [ -e "$REPO_DIR/settings.yaml" ]; then
        echo "Keeping $REPO_DIR/settings.yaml"
    else
        cp "$REPO_DIR/settings.example.yaml" "$REPO_DIR/settings.yaml"
        echo "Created $REPO_DIR/settings.yaml with no folder pairs; add them with: proton-drive-linux-sync"
    fi
}

enable_continuous_sync() {
    "$REPO_DIR/proton-sync-tui.sh" --schedule watch
}

install_sync_command() {
    "$REPO_DIR/proton-sync-tui.sh" --install
}

ensure_not_root
ensure_proton_cli
print_step "[1/4] Installing system packages"
install_apt_packages
print_step "[2/4] Creating settings"
create_settings_from_example
print_step "[3/4] Turning on continuous sync"
enable_continuous_sync
print_step "[4/4] Installing the proton-drive-linux-sync command"
install_sync_command
print_step "Setup done. Settings: $REPO_DIR/settings.yaml. Recent syncs: proton-drive-linux-sync --log"
