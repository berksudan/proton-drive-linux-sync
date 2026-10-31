# ============================================================
# SYNC SCREENS
# ============================================================

# Re-check the login before a sync (the session may have expired).
preflight() {
    ui_infobox "Please Wait" "Checking your Proton Drive login..."
    if ! is_authenticated; then
        if ! ensure_authenticated; then
            ui_msgbox "Not Logged In" "Can't open $REMOTE_DIR on Proton Drive, so the sync can't run."
            return 1
        fi
    fi
    AUTH_STATE=in
    return 0
}

# run_sync_with_gauge DRY_RUN — run one sync (or preview) with a progress bar.
# run_sync_with_gauge DRY_RUN [quiet] — quiet (for Sync all) skips the
# summary; LAST_RESULT holds the outcome either way.
run_sync_with_gauge() {
    local dry="$1" quiet="${2:-}"
    [ "$FORCE_DRY_RUN" = true ] && dry=true
    DRY_RUN="$dry"

    LAST_RESULT="not logged in"
    preflight || return

    if ! acquire_lock; then
        LAST_RESULT="another sync was running"
        ui_msgbox "Sync Already Running" "Another sync is running right now (lock: $LOCK_FILE).

Wait for it to finish, then try again."
        return
    fi

    LOG_FILE="$LOG_DIR/sync-$(date +%Y%m%d-%H%M%S).log"
    LOCAL_TRASH="$TRASH_DIR/$(date +%Y%m%d-%H%M%S)"

    local title="${SYNC_TITLE:-Syncing}"
    [ "$dry" = true ] && title="Preview (no changes are made)"

    local conflict_dump="$STATE_DIR/conflicts.tmp"
    : > "$conflict_dump"

    # Feed the gauge through a process substitution rather than a pipeline,
    # so sync_engine runs in this shell and its counters and status survive.
    local engine_rc=0
    sync_engine "$conflict_dump" > >(ui_gauge "$title") || engine_rc=$?
    wait "$!" 2>/dev/null || true

    if [ "$engine_rc" -ne 0 ]; then
        # Stopped before any changes: keep the existing snapshot untouched.
        rm -f "$conflict_dump" "$NEW_SNAPSHOT" "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"
        release_lock
        if [ "$engine_rc" -eq 2 ]; then
            confirm_large_deletion "$quiet"
        elif [ "$engine_rc" -eq 4 ]; then
            confirm_empty_local "$quiet"
        else
            record_result "Stopped: $ABORT_REASON"
            LAST_RESULT="Stopped: $ABORT_REASON"
            ui_msgbox "Sync Stopped" "$ABORT_REASON

No changes were made. Details are in the log:
$LOG_FILE"
        fi
        return
    fi

    load_conflicts "$conflict_dump"
    if [ "${#CONFLICTS[@]}" -gt 0 ] && [ "$DRY_RUN" != true ]; then
        resolve_all_conflicts
    fi
    rm -f "$conflict_dump"

    finalize_snapshot
    release_lock

    LAST_RESULT=$(result_text)
    if [ "$DRY_RUN" = true ]; then
        record_result "Preview: $LAST_RESULT"
        show_preview
    else
        record_result "$LAST_RESULT"
        [ -z "$quiet" ] && show_summary
    fi
    return 0
}

show_preview() {
    if ! grep -qvE $'^(skipped|note)\t' "$PLAN_FILE" 2>/dev/null; then
        local extra=""
        [ "$(plan_count skipped)" -gt 0 ] && extra=$'\n\n'"$(plan_count skipped) file(s) aren't synced (Proton Docs or over the size limit)."
        ui_msgbox "Preview" "Everything is already in sync. There's nothing to do.$extra"
        return
    fi
    local view="$STATE_DIR/view.txt" headline
    format_plan > "$view"
    headline=$(head -1 "$view")
    ui_textbox "Preview: what a sync would change" "$view"
    rm -f "$view"
    [ "$FORCE_DRY_RUN" = true ] && return
    if ui_yesno "Preview" "Run this sync now?

$headline" "Run sync now" "Not now"; then
        run_sync_with_gauge false
    fi
}

show_summary() {
    local text n_failed
    if [ "$COUNT_ERRORS" -gt 0 ]; then
        text="The sync finished with $COUNT_ERRORS error(s)."
    else
        text="Sync complete."
    fi
    text+=$'\n\n'"$(sync_summary)"
    n_failed=$(plan_count failed)
    if [ "$n_failed" -gt 0 ]; then
        text+=$'\n\nProblems:\n'"$(grep "^failed"$'\t' "$PLAN_FILE" | cut -f2- | head -8 | sed 's/^/  /')"
        [ "$n_failed" -gt 8 ] && text+=$'\n'"  ...and $((n_failed - 8)) more (see the log)"
        text+=$'\n\nFailed items are tried again on the next sync.'
    fi
    if ui_yesno "Sync Summary" "$text" "View log" "Close"; then
        view_log "$LOG_FILE"
    fi
}

# The sync stopped because it would delete more than the safety limit.
confirm_large_deletion() {
    local quiet="${1:-}" n view="$STATE_DIR/view.txt"
    n=$(wc -l < "$PENDING_DELETES")
    {
        echo "$ABORT_REASON"
        echo
        echo "Nothing has been changed yet. If you go ahead, local files go to the"
        echo "local trash (see Restore deleted files) and files on Proton go to"
        echo "Proton's trash."
        echo
        cat "$PENDING_DELETES"
    } > "$view"
    ui_textbox "Large Deletion: $n files" "$view"
    rm -f "$view"
    if ui_yesno "Large Deletion" "Delete these $n files and finish the sync?" "Delete and sync" "Cancel"; then
        ALLOW_DELETES=true
        run_sync_with_gauge false "$quiet"
        ALLOW_DELETES="${PROTON_SYNC_ALLOW_DELETES:-false}"
    else
        record_result "Stopped: $n deletions not confirmed"
        LAST_RESULT="Stopped: $n deletions not confirmed"
        ui_msgbox "Sync Cancelled" "Nothing was changed. The next sync will ask again."
    fi
}

# The local folder is empty or missing although files were synced from it.
confirm_empty_local() {
    local quiet="${1:-}" n="${#SNAPSHOT_LOCAL_FP[@]}" choice text
    local -a items=()
    if [ "$EMPTY_LOCAL" = missing ]; then
        text="The local folder doesn't exist:
  $(display_path "$LOCAL_DIR")

but $n files were synced from it before. If it's on a drive that isn't connected, connect the drive and try again.

Nothing has been changed."
        items=(fresh "Create it and download everything from Proton (start fresh)")
    else
        text="The local folder is empty:
  $(display_path "$LOCAL_DIR")

but $n files were synced from it before. This usually means a drive isn't mounted, or you're setting up this computer again.

Nothing has been changed."
        items=(fresh "Download everything from Proton (start fresh)")
        [ "$SYNC_MODE" = two-way ] && items+=(deleted "I deleted them: delete them on Proton too")
    fi
    items+=(cancel "Cancel")
    choice=$(ui_menu "Local Folder Is $EMPTY_LOCAL" "$text" "" fresh "${items[@]}") || choice=cancel
    case "$choice" in
        fresh)
            start_fresh
            mkdir -p "$LOCAL_DIR"
            run_sync_with_gauge false "$quiet"
            ;;
        deleted)
            EMPTY_OK=true; ALLOW_DELETES=true
            run_sync_with_gauge false "$quiet"
            EMPTY_OK=false; ALLOW_DELETES="${PROTON_SYNC_ALLOW_DELETES:-false}"
            ;;
        *)
            record_result "Stopped: local folder is $EMPTY_LOCAL"
            LAST_RESULT="Stopped: local folder is $EMPTY_LOCAL"
            ;;
    esac
}
