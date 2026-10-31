# ============================================================
# HEADLESS MODE
# ============================================================

# Sync the current folder pair without dialogs or prompts.
# Returns 0 on success, 1 on any failure, error or stop, 3 if another
# sync holds the lock.
headless_sync() {
    local label
    label=$(pair_label "$CURRENT_PAIR")
    echo "== $label ($(mode_label "$SYNC_MODE")) $(date '+%Y-%m-%d %H:%M')"
    [ "$DRY_RUN" = true ] && echo "Mode:    DRY RUN (no changes will be made)"

    if ! acquire_lock; then
        echo "ERROR: Another sync is already running (lock: $LOCK_FILE)" >&2
        echo "If you are sure no sync is running, remove it manually:" >&2
        echo "  rmdir '$LOCK_FILE'" >&2
        return 3
    fi

    if ! is_authenticated; then
        release_lock
        record_result "Stopped: not logged in to Proton Drive"
        notify critical "Proton Drive Linux Sync stopped" "Not logged in to Proton Drive. Run: proton-drive auth login"
        echo "ERROR: Cannot access $REMOTE_DIR — are you logged in?" >&2
        echo "Run: proton-drive auth login" >&2
        return 1
    fi

    # Conflicts can't be asked about without a terminal; leave them unresolved.
    local strategy="$CONFLICT_STRATEGY"
    [ "$strategy" = "ask" ] && CONFLICT_STRATEGY=skip

    LOG_FILE="$LOG_DIR/sync-$(date +%Y%m%d-%H%M%S).log"
    LOCAL_TRASH="$TRASH_DIR/$(date +%Y%m%d-%H%M%S)"
    local conflict_dump="$STATE_DIR/conflicts.tmp" rc=0
    : > "$conflict_dump"

    # Run in the current shell (not a pipeline) so the counters survive.
    sync_engine "$conflict_dump" >/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$conflict_dump" "$NEW_SNAPSHOT" "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"
        release_lock
        CONFLICT_STRATEGY="$strategy"
        echo "ERROR: $ABORT_REASON" >&2
        echo "No changes were made." >&2
        if [ "$rc" -eq 2 ]; then
            local n
            n=$(wc -l < "$PENDING_DELETES")
            record_result "Stopped: $n deletions need confirmation"
            notify critical "Proton Drive Linux Sync stopped" "$label: $n files would be deleted. Open the menu and choose Sync now to review them."
            echo >&2
            echo "Files that would be deleted:" >&2
            head -20 "$PENDING_DELETES" | sed 's/^/  /' >&2
            [ "$n" -gt 20 ] && echo "  ...and $((n - 20)) more" >&2
            echo >&2
            echo "To go ahead, run a sync from the menu, or run:" >&2
            echo "  $SCRIPT_PATH --headless --allow-deletes" >&2
        elif [ "$rc" -eq 4 ]; then
            record_result "Stopped: local folder is $EMPTY_LOCAL"
            notify critical "Proton Drive Linux Sync stopped" "$label: the local folder is $EMPTY_LOCAL. Connect the drive, or open the menu to download everything again."
            echo >&2
            echo "If the folder is on a drive that isn't connected, connect it and sync again." >&2
            echo "To download everything from Proton again (start fresh), run:" >&2
            echo "  $SCRIPT_PATH --headless --start-fresh --pair $((CURRENT_PAIR + 1))" >&2
            echo "If you deleted everything on purpose, run a sync from the menu." >&2
        else
            record_result "Stopped: $ABORT_REASON"
            notify critical "Proton Drive Linux Sync stopped" "$label: $ABORT_REASON"
        fi
        echo "Log: $LOG_FILE" >&2
        return 1
    fi

    load_conflicts "$conflict_dump"
    if [ "${#CONFLICTS[@]}" -gt 0 ] && [ "$DRY_RUN" != true ]; then
        resolve_all_conflicts
    fi
    rm -f "$conflict_dump"

    finalize_snapshot
    release_lock

    local result
    result=$(result_text)
    if [ "$DRY_RUN" = true ]; then
        record_result "Preview: $result"
        format_plan
    else
        record_result "$result"
        echo "=== Sync Summary ==="
        sync_summary | sed 's/^/  /'
        if [ "$(plan_count failed)" -gt 0 ]; then
            echo "Problems (retried on the next sync):"
            grep "^failed"$'\t' "$PLAN_FILE" | cut -f2- | sed 's/^/  /'
        fi
        if [ "$CONFLICT_STRATEGY" = "skip" ] && [ "$COUNT_CONFLICTS" -gt 0 ]; then
            echo "  ($COUNT_CONFLICTS conflict(s) left unresolved; sync from the menu to resolve them)"
        fi
        if [ "$COUNT_ERRORS" -gt 0 ]; then
            notify normal "Proton Drive Linux Sync had problems" "$label: $result"
        elif [ "$CONFLICT_STRATEGY" = "skip" ] && [ "$COUNT_CONFLICTS" -gt 0 ]; then
            notify normal "Proton Drive Linux Sync: conflicts" "$label: $COUNT_CONFLICTS file(s) changed on both sides. Open the menu and choose Sync now to resolve them."
        elif [ "$NOTIFY" = changes ] && [ "$result" != "no changes, no errors" ]; then
            notify low "Proton Drive synced" "$label: $result"
        fi
    fi
    CONFLICT_STRATEGY="$strategy"
    echo "Log: $LOG_FILE"

    [ "$COUNT_ERRORS" -eq 0 ]
}

# Sync the chosen pairs (all by default). Returns the worst result:
# 0 ok, 1 a pair failed, 3 a pair was skipped because another sync ran.
headless_run() {
    local i rc worst=0
    local -a pairs=("${!PAIR_LOCAL[@]}")
    [ -n "$ONLY_PAIR" ] && pairs=("$ONLY_PAIR")
    if [ "${#pairs[@]}" -eq 0 ]; then
        echo "No folder pairs set up, so there is nothing to sync. Add one with: proton-drive-linux-sync (Folder pairs)"
        return 0
    fi
    for i in "${pairs[@]}"; do
        select_pair "$i"
        if [ "$START_FRESH" = true ] && [ "$DRY_RUN" != true ]; then
            start_fresh
            echo "Sync history for $(pair_label "$i") cleared; syncing as if for the first time."
        fi
        rc=0
        headless_sync || rc=$?
        echo
        if [ "$rc" -eq 1 ] || { [ "$rc" -eq 3 ] && [ "$worst" -eq 0 ]; }; then
            worst="$rc"
        fi
    done
    return "$worst"
}
