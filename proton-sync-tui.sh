#!/bin/bash
set -uo pipefail

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
APP_DIR=$(dirname "$SCRIPT_PATH")
LIB_DIR="$APP_DIR/lib"

MODULES=(
    settings pairs state logging run_log lock execution local_files proton
    conflicts transfers plan folder_deletions engine text schedule headless watch install cli
    tui/widgets tui/sync_screens tui/conflict_screens tui/history_screens
    tui/restore_screens tui/settings_screens tui/pair_screens tui/account_screen
    tui/schedule_screen tui/main_menu
)
for module in "${MODULES[@]}"; do
    # shellcheck source=/dev/null
    source "$LIB_DIR/$module.sh" || { echo "ERROR: couldn't load $LIB_DIR/$module.sh" >&2; exit 1; }
done

run_cli "$@"
