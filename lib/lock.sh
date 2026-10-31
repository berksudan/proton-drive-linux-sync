# ============================================================
# LOCKING
# ============================================================

# The lock is a folder holding the PID of the sync that owns it. A lock
# left behind by a sync that is no longer running (a crash, kill -9 or
# power loss) is removed automatically.
LOCK_HELD=false
WATCH_PID=""
WATCH_FIFO=""

# Runs on exit: release the lock if we hold it, stop the file watcher.
cleanup_on_exit() {
    [ "$LOCK_HELD" = true ] && rm -rf "$LOCK_FILE"
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    [ -n "$WATCH_FIFO" ] && rm -f "$WATCH_FIFO"
    return 0
}
trap cleanup_on_exit EXIT

acquire_lock() {
    local attempt
    for attempt in 1 2; do
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            echo "$$" > "$LOCK_FILE/pid"
            LOCK_HELD=true
            return 0
        fi
        lock_is_stale || return 1
        rm -rf "$LOCK_FILE"
        log "Removed a stale lock left by a sync that is no longer running"
    done
    return 1
}

lock_is_stale() {
    local pid=""
    [ -r "$LOCK_FILE/pid" ] && read -r pid < "$LOCK_FILE/pid"
    if [ -z "$pid" ]; then
        # No PID: made by an older version, or a sync that is just starting.
        # Only treat it as stale once it is 12 hours old.
        [ -n "$(find "$LOCK_FILE" -maxdepth 0 -mmin +720 2>/dev/null)" ]
        return
    fi
    kill -0 "$pid" 2>/dev/null || return 0
    # The PID is alive; if it was reused by an unrelated program, the lock is stale.
    if [ -r "/proc/$pid/cmdline" ] && ! tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q proton; then
        return 0
    fi
    return 1
}

release_lock() {
    rm -rf "$LOCK_FILE"
    LOCK_HELD=false
}
