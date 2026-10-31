# ============================================================
# SETTINGS SCREENS
# ============================================================

settings_menu() {
    local choice=conflict
    while true; do
        choice=$(ui_menu "Settings" "Changes are saved right away and used by automatic syncs too. Folders are set under Folder pairs." \
            "Back" "$choice" \
            conflict "Conflicts:            $(conflict_label)" \
            jobs     "Parallel transfers:   $SYNC_JOBS" \
            deletes  "Confirm deletions:    $(delete_limit_text)" \
            maxsize  "Skip files larger than: $( [ "$MAX_FILE_SIZE_MB" -gt 0 ] && echo "$MAX_FILE_SIZE_MB MB" || echo "no limit" )" \
            excludes "Excluded names:       ${EXCLUDE_PATTERNS[*]}" \
            notify   "Notifications:        $(notify_label)" \
            poll     "Continuous sync checks Proton every: $WATCH_POLL_MINUTES min" \
            trash    "Keep local trash:     $(days_text "$TRASH_RETENTION_DAYS")" \
            logdays  "Keep logs:            $(days_text "$LOG_RETENTION_DAYS")" \
            debug    "Debug logging:        $( [ "$DEBUG" = true ] && echo on || echo off )" \
            where    "Where settings, logs and trash are stored") || return
        case "$choice" in
            conflict) choose_conflict_strategy ;;
            jobs)     ask_number "Parallel Transfers" "How many transfers and folder listings should run at the same time? (1-16)

Lower this if Proton Drive starts refusing requests." SYNC_JOBS 1 16 ;;
            deletes)  ask_delete_limits ;;
            maxsize)  ask_number "File Size Limit" "Skip files larger than how many MB? (0 = no limit)

Skipped files are listed under \"Not synced\" in Preview, and are never deleted because of the limit." MAX_FILE_SIZE_MB 0 10000000 ;;
            excludes) edit_excludes ;;
            notify)   choose_notifications ;;
            poll)     ask_number "Continuous Sync" "With continuous automatic sync, local changes are synced within seconds. How often should Proton Drive be checked for changes, in minutes? (1-1440)" WATCH_POLL_MINUTES 1 1440 ;;
            trash)    ask_number "Local Trash" "Keep files that syncs delete locally for how many days? (0 = keep until you delete them)" TRASH_RETENTION_DAYS 0 36500 ;;
            logdays)  ask_number "Logs" "Keep sync logs for how many days? (0 = keep forever)" LOG_RETENTION_DAYS 0 36500 ;;
            debug)    if [ "$DEBUG" = true ]; then set_setting DEBUG false; else set_setting DEBUG true; fi ;;
            where)    show_locations ;;
        esac
    done
}

notify_label() {
    case "$NOTIFY" in
        off)      echo "off" ;;
        problems) echo "when something needs attention" ;;
        changes)  echo "problems and every sync with changes" ;;
    esac
}

choose_notifications() {
    local value
    value=$(ui_menu "Notifications" "Desktop notifications from automatic (background) syncs:" "Back" "$NOTIFY" \
        off      "Off" \
        problems "When something needs attention (errors, stops, conflicts)" \
        changes  "Also after every sync that changed files") || return
    set_setting NOTIFY "$value"
    if [ "$value" != off ] && ! command -v notify-send >/dev/null 2>&1; then
        ui_msgbox "Notifications" "Notifications need the notify-send command, which isn't installed.

Install it (for example: sudo apt install libnotify-bin, or sudo dnf install libnotify)."
    fi
}

days_text() {
    if [ "$1" -eq 0 ]; then echo "forever"; else echo "$1 days"; fi
}

# ask_number TITLE TEXT KEY MIN MAX — returns 1 if cancelled.
ask_number() {
    local title="$1" text="$2" key="$3" min="$4" max="$5" value
    while true; do
        value=$(ui_input "$title" "$text" "${!key}") || return 1
        value="${value// /}"
        if is_number "$value" && [ "$((10#$value))" -ge "$min" ] && [ "$((10#$value))" -le "$max" ]; then
            set_setting "$key" "$((10#$value))"
            return 0
        fi
        ui_msgbox "$title" "Please enter a whole number from $min to $max."
    done
}

ask_delete_limits() {
    ask_number "Confirm Deletions" "Ask before a sync deletes more than how many files? (0 = no limit)

Automatic syncs stop instead of asking; run a sync from the menu to confirm." \
        DELETE_CONFIRM_COUNT 0 100000000 || return
    ask_number "Confirm Deletions" "Also ask when a sync would delete more than what percentage of your synced files? (0 = off)

This only applies when 5 or more files would be deleted." \
        DELETE_CONFIRM_PERCENT 0 100
}

edit_excludes() {
    local value
    local -a patterns=()
    value=$(ui_input "Excluded Names" "Files and folders with these names are never synced. Separate names with spaces; * and ? work as wildcards.

Example: *.tmp .git node_modules" "${EXCLUDE_PATTERNS[*]}") || return
    read -ra patterns <<< "$value"
    EXCLUDE_PATTERNS=("${patterns[@]+"${patterns[@]}"}")
    CFG_EXCLUDE_PATTERNS=("${patterns[@]+"${patterns[@]}"}")
    save_config
}

choose_conflict_strategy() {
    local value
    value=$(ui_menu "Conflicts" "When a file changed both here and on Proton Drive since the last sync:" \
        "Back" "$CONFLICT_STRATEGY" \
        ask    "Ask me each time (automatic syncs skip the file instead)" \
        local  "Keep the local version" \
        remote "Keep the Proton version" \
        both   "Keep both (local wins; Proton version saved as a .remote copy)" \
        skip   "Skip it and leave both versions as they are") || return
    set_setting CONFLICT_STRATEGY "$value"
}

show_locations() {
    ui_msgbox "Where Things Are Stored" "Settings:      $CONFIG_FILE

For $(pair_label "$CURRENT_PAIR"):
Sync history:  $STATE_DIR
Logs:          $LOG_DIR
Local trash:   $TRASH_DIR

Automatic sync output: $STATE_ROOT/cron.log (cron), or
  journalctl --user -u proton-drive-linux-sync (systemd)

Each folder pair has its own history, logs and trash."
}
