# ============================================================
# COMMAND LINE
# ============================================================

# --status: what's configured and how the last syncs went (no network).
print_status() {
    local i
    echo "Proton Drive Linux Sync"
    echo "Settings:        $CONFIG_FILE"
    echo "Automatic sync:  $(schedule_text)$( [ -n "$(schedule_backend)" ] && echo " ($(schedule_backend))")"
    if [ -d "$LOCK_FILE" ] && ! lock_is_stale; then
        echo "Sync running:    yes"
    fi
    echo
    [ "$(pair_count)" -eq 0 ] && echo "No folder pairs set up, so nothing is synced. Add one with: proton-drive-linux-sync (Folder pairs)"
    for i in "${!PAIR_LOCAL[@]}"; do
        echo "$((i + 1)). $(pair_label "$i")"
        echo "   Mode:       $(mode_label "${PAIR_MODE[$i]}")"
        echo "   Last sync:  $(pair_last_sync "$i")"
    done
}

print_version() {
    local version
    version=$(git --git-dir="$APP_DIR/.git" --work-tree="$APP_DIR" describe --tags --always --dirty) || return 1
    echo "Proton Drive Linux Sync $version"
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

  (no options)     Start the interactive menu.
  --headless       Sync all folder pairs without the menu (for cron/systemd)
                   and exit. Also used automatically when there is no terminal.
  --pair N         With --headless or --dry-run: sync only folder pair N.
  --dry-run        Preview only; make no changes (same as PROTON_SYNC_DRY_RUN=true).
  --allow-deletes  Don't stop when a sync would delete more files than the
                   safety limit set in Settings.
  --start-fresh    Forget a folder pair's sync history and sync it as if for
                   the first time: files on only one side are copied to the
                   other, nothing is deleted. Needs --pair N if you have
                   several pairs.
  --watch          Continuous sync: sync local changes within seconds and
                   check Proton regularly. Runs until stopped.
  --status         Show folder pairs, last results and automatic sync, then exit.
  --log [-n N] [-f]
                   Show the last N sync runs from the run log (default 20);
                   -f keeps showing new runs until stopped.
  --schedule KIND  Set automatic sync without the menu, then exit. KIND is
                   off, hourly, six (every 6 hours), daily or watch (continuous).
  --install        Link ~/.local/bin/proton-drive-linux-sync to this script and
                   add a desktop launcher. Settings stay in settings.yaml.
  --uninstall      Remove that link and the launcher (keeps your settings
                   and sync history).
  --version        Show the installed version (the repo's git version).
  --help           Show this help.

Settings are read from $CONFIG_FILE
USAGE
}

ensure_settings_tools() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: reading the settings needs jq. Install it with: sudo apt install jq" >&2
        exit 1
    fi
    if ! python3 -c 'import yaml' >/dev/null 2>&1; then
        echo "ERROR: reading the settings needs Python 3 with PyYAML. Install it with: sudo apt install python3-yaml" >&2
        exit 1
    fi
}

run_cli() {
    HEADLESS=false
    START_FRESH=false
    ACTION=menu
    ONLY_PAIR=""
    SCHEDULE_KIND=""
    FOLLOW=false
    LOG_LINES=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --headless|--sync) HEADLESS=true ;;
            --dry-run) FORCE_DRY_RUN=true; DRY_RUN=true ;;
            --allow-deletes) ALLOW_DELETES=true ;;
            --start-fresh) START_FRESH=true ;;
            --pair|--pair=*)
                if [ "$1" = --pair ]; then shift; n="${1:-}"; else n="${1#--pair=}"; fi
                if ! is_number "$n" || [ "$n" -lt 1 ]; then
                    echo "--pair needs a folder pair number (see --status)" >&2; exit 2
                fi
                ONLY_PAIR=$((n - 1)) ;;
            --watch) ACTION=watch ;;
            --status) ACTION=status ;;
            --log) ACTION=log ;;
            -f|--follow) FOLLOW=true ;;
            -n|--lines|--lines=*)
                if [ "$1" = --lines ] || [ "$1" = -n ]; then shift; LOG_LINES="${1:-}"; else LOG_LINES="${1#--lines=}"; fi
                if ! is_number "$LOG_LINES" || [ "$LOG_LINES" -lt 1 ]; then
                    echo "-n needs a number of sync runs to show" >&2; exit 2
                fi ;;
            --schedule|--schedule=*)
                if [ "$1" = --schedule ]; then shift; SCHEDULE_KIND="${1:-}"; else SCHEDULE_KIND="${1#--schedule=}"; fi
                case "$SCHEDULE_KIND" in
                    off|hourly|six|daily|watch) ;;
                    *) echo "--schedule needs one of: off, hourly, six, daily, watch" >&2; exit 2 ;;
                esac
                ACTION=schedule ;;
            --install) ACTION=install ;;
            --uninstall) ACTION=uninstall ;;
            --version) print_version; exit $? ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    if [ "$FOLLOW" = true ] && [ "$ACTION" != log ]; then
        echo "-f only works with --log" >&2; exit 2
    fi
    if [ -n "$LOG_LINES" ] && [ "$ACTION" != log ]; then
        echo "-n only works with --log" >&2; exit 2
    fi

    ensure_settings_tools
    load_config
    validate_settings "$CONFIG_FILE"
    remember_saved_settings
    apply_env_overrides
    validate_settings "the PROTON_SYNC_* environment variables"
    mkdir -p "$STATE_ROOT"

    if [ "$START_FRESH" = true ] && [ -z "$ONLY_PAIR" ] && [ "$(pair_count)" -gt 1 ]; then
        echo "--start-fresh needs --pair N when there is more than one folder pair (see --status)." >&2
        exit 2
    fi
    [ "$START_FRESH" = true ] && HEADLESS=true
    if [ -n "$ONLY_PAIR" ] && [ "$ONLY_PAIR" -ge "$(pair_count)" ]; then
        echo "There is no folder pair $((ONLY_PAIR + 1)); there are $(pair_count) (see --status)." >&2
        exit 2
    fi
    [ "$(pair_count)" -gt 0 ] && select_pair "${ONLY_PAIR:-0}"

    case "$ACTION" in
        status)    print_status; exit 0 ;;
        log)       show_run_log "$FOLLOW" "${LOG_LINES:-20}"; exit $? ;;
        schedule)  schedule_from_cli "$SCHEDULE_KIND"; exit $? ;;
        install)   install_script; exit $? ;;
        uninstall) uninstall_script; exit $? ;;
    esac

    # No terminal (cron, systemd, piped) means the menu can't work.
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        HEADLESS=true
    fi

    if ! command -v proton-drive >/dev/null 2>&1; then
        echo "ERROR: 'proton-drive' command not found in PATH." >&2
        exit 1
    fi

    if [ "$ACTION" = watch ]; then
        watch_mode
        exit $?
    fi

    if [ "$HEADLESS" = true ]; then
        rotate_log "$STATE_ROOT/cron.log"
        rc=0
        headless_run || rc=$?
        [ "$rc" -eq 0 ] || exit 1
        exit 0
    fi

    if ! find_ui_tool; then
        echo "ERROR: the menu needs 'dialog' or 'whiptail'. Install one with:"
        echo "  sudo apt install dialog     # Debian/Ubuntu"
        echo "  sudo dnf install dialog     # Fedora"
        echo "Or run a single sync without the menu: $0 --headless"
        exit 1
    fi

    # Verify the login before showing the menu; offer to log in if needed.
    ui_infobox "Please Wait" "Checking your Proton Drive login..."
    if ! ensure_authenticated; then
        clear
        echo "Proton Drive login is required to continue."
        echo "Exiting."
        exit 1
    fi

    if [ "$(pair_count)" -eq 0 ]; then
        ui_msgbox "No Folder Pairs" "Nothing is synced until you add a folder pair: a local folder and the Proton Drive folder to keep in sync with it."
        add_pair
        [ "$(pair_count)" -gt 0 ] || { clear; echo "No folder pair added; nothing to sync."; exit 0; }
    fi
    main_menu
}
