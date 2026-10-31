# event_needs_sync PATH — 0 if PATH changed in a way the last sync hasn't
# recorded (the user changed something), 1 if it's the sync's own doing or
# irrelevant (excluded names, download-only folders, folders).
event_needs_sync() {
    local path="$1" i rel snap fp
    for i in "${!PAIR_LOCAL[@]}"; do
        [ "${PAIR_MODE[$i]}" = download ] && continue
        case "$path" in "${PAIR_LOCAL[$i]}"/*) ;; *) continue ;; esac
        rel="${path#"${PAIR_LOCAL[$i]}"/}"
        is_excluded "$rel" && return 1
        snap="$(pair_state_dir "${PAIR_LOCAL[$i]}" "${PAIR_REMOTE[$i]}")/snapshot"
        if [ -d "$path" ]; then
            return 1
        elif [ -f "$path" ]; then
            fp=$(get_local_fingerprint "$path")
            grep -qF "file${SEP}${rel}${SEP}${fp}${SEP}" "$snap" 2>/dev/null && return 1
            return 0
        else
            # Gone: a change only if the last sync recorded it as present.
            grep -qF "file${SEP}${rel}${SEP}" "$snap" 2>/dev/null
            return
        fi
    done
    return 1
}

# Continuous sync: sync a few seconds after local changes stop, and check
# Proton for changes every WATCH_POLL_MINUTES. Runs until stopped.
watch_mode() {
    if ! command -v inotifywait >/dev/null 2>&1; then
        echo "ERROR: continuous sync needs inotifywait (for example: sudo apt install inotify-tools)" >&2
        return 1
    fi
    local -a dirs=()
    local i
    for i in "${!PAIR_LOCAL[@]}"; do
        [ "${PAIR_MODE[$i]}" = download ] && continue
        [ -d "${PAIR_LOCAL[$i]}" ] && dirs+=("${PAIR_LOCAL[$i]}")
    done

    local config_stamp
    WATCH_FIFO=$(mktemp -u "$STATE_ROOT/watch.XXXXXX")
    mkfifo "$WATCH_FIFO" || return 1
    exec 3<>"$WATCH_FIFO"
    if [ "${#dirs[@]}" -gt 0 ]; then
        inotifywait -m -r -q -e close_write,create,delete,move,attrib --format '%w%f' \
            "${dirs[@]}" >&3 2>>"$STATE_ROOT/watch.log" &
        WATCH_PID=$!
    fi
    trap 'exit 0' TERM INT
    config_stamp=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null || echo 0)

    echo "Continuous sync started $(date '+%Y-%m-%d %H:%M'): watching ${#dirs[@]} folder(s), checking Proton every $WATCH_POLL_MINUTES min."
    local poll=$((WATCH_POLL_MINUTES * 60)) next_poll now remaining path rc pending=false reason
    headless_run
    next_poll=$(( $(date +%s) + poll ))

    while true; do
        if [ "$pending" = false ]; then
            now=$(date +%s); remaining=$((next_poll - now)); ((remaining < 1)) && remaining=1
            rc=0
            read -r -t "$remaining" -u 3 path || rc=$?
            if [ "$rc" -eq 0 ]; then
                event_needs_sync "$path" || continue
                reason="local changes"
            elif [ "$rc" -gt 128 ]; then
                reason="checking Proton Drive"
            else
                echo "ERROR: the file watcher stopped (see $STATE_ROOT/watch.log)" >&2
                return 1
            fi
        fi
        if [ -n "$WATCH_PID" ] && ! kill -0 "$WATCH_PID" 2>/dev/null; then
            echo "ERROR: the file watcher stopped (see $STATE_ROOT/watch.log)" >&2
            return 1
        fi
        # Wait until changes settle (at most a minute).
        local settle_end=$(( $(date +%s) + 60 ))
        while [ "$(date +%s)" -lt "$settle_end" ] && read -r -t "$WATCH_DELAY_SECONDS" -u 3 path; do :; done

        # Pick up changed settings or folder pairs by restarting.
        if [ "$(stat -c %Y "$CONFIG_FILE" 2>/dev/null || echo 0)" != "$config_stamp" ]; then
            echo "Settings changed; restarting."
            cleanup_on_exit
            exec bash "$SCRIPT_PATH" --watch
        fi

        echo "=== $(date '+%Y-%m-%d %H:%M:%S'): syncing ($reason)"
        rc=0
        headless_run || rc=$?
        pending=false
        next_poll=$(( $(date +%s) + poll ))
        if [ "$rc" -eq 3 ]; then
            # Another sync was running; try again shortly.
            pending=true; reason="retry"
            sleep 30
            continue
        fi
        # Changes made while syncing (other than the sync's own) need another run.
        while read -r -t 1 -u 3 path; do
            event_needs_sync "$path" && { pending=true; reason="changes during the last sync"; }
        done
    done
}
