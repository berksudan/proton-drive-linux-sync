# ============================================================
# LOGGING
# ============================================================

log() {
    echo "$*" >> "$LOG_FILE"
}

cleanup_old_logs() {
    [ "$DRY_RUN" = true ] && return 0
    [ "$LOG_RETENTION_DAYS" -gt 0 ] || return 0
    find "$LOG_DIR" -maxdepth 1 -type f -name 'sync-*.log' \
        -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# notify URGENCY TITLE BODY — desktop notification from background syncs.
notify() {
    [ "$NOTIFY" = off ] && return 0
    [ "$DRY_RUN" = true ] && return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    local bus
    bus="/run/user/$(id -u)/bus"
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"
    fi
    notify-send -a "Proton Drive Sync" -u "$1" "$2" "$3" >/dev/null 2>&1 || true
}

rotate_log() {
    local f="$1"
    if [ -f "$f" ] && [ "$(stat -c %s "$f")" -gt 1048576 ]; then
        mv -f "$f" "$f.1"
    fi
}
