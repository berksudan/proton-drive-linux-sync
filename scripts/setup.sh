#!/bin/bash
set -euo pipefail

REPO_DIR=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
STATE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/proton-sync"
APT_PACKAGES=(dialog inotify-tools jq libnotify-bin)

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
        echo "ERROR: proton-drive CLI not found. Install it from https://proton.me/drive, then rerun." >&2
        exit 1
    }
}

run_as_root() {
    echo "sudo needed for: $*"
    sudo -p "[sudo] password for %u: " "$@"
}

install_apt_packages() {
    run_as_root apt-get install -y -qq "${APT_PACKAGES[@]}"
}

link_run_logs_into_repo() {
    mkdir -p "$REPO_DIR/logs" "$STATE_ROOT"
    ln -sfnT "$REPO_DIR/logs" "$STATE_ROOT/run-logs"
    echo "Run log: $REPO_DIR/logs/runs.log"
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
print_step "[2/4] Keeping the run log in this repo"
link_run_logs_into_repo
print_step "[3/4] Turning on continuous sync"
enable_continuous_sync
print_step "[4/4] Installing the proton-drive-sync command"
install_sync_command
print_step "Setup done. Add folders and change settings with: proton-drive-sync"
