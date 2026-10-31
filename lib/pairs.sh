# ============================================================
# PER-FOLDER-PAIR STATE
# Sync history, logs and local trash are kept separately for each
# local/remote folder pair, so switching folders never compares one
# folder against another folder's history.
# ============================================================

pair_id() {
    printf '%s\n%s' "$1" "$2" | sha256sum | cut -c1-12
}

init_state_paths() {
    STATE_DIR="$STATE_ROOT/pairs/$(pair_id "$LOCAL_DIR" "$REMOTE_DIR")"
    SNAPSHOT="$STATE_DIR/snapshot"
    NEW_SNAPSHOT="$STATE_DIR/snapshot.new"
    LOCAL_MANIFEST="$STATE_DIR/local_manifest"
    REMOTE_MANIFEST="$STATE_DIR/remote_manifest"
    JOB_RESULTS="$STATE_DIR/job_results"
    PLAN_FILE="$STATE_DIR/plan"
    PENDING_DELETES="$STATE_DIR/pending_deletions"
    STATUS_FILE="$STATE_DIR/last_status"
    LOG_DIR="$STATE_DIR/logs"
    TRASH_DIR="$STATE_DIR/trash"
    LOCAL_TRASH="$TRASH_DIR/$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="$LOG_DIR/sync-$(date +%Y%m%d-%H%M%S).log"

    mkdir -p "$STATE_DIR" "$LOG_DIR"
    printf 'Local:  %s\nProton: %s\n' "$LOCAL_DIR" "$REMOTE_DIR" > "$STATE_DIR/folders"
    migrate_legacy_state
    touch "$SNAPSHOT"
}

# Older versions kept one snapshot, log folder and trash directly in
# $STATE_ROOT. Hand them to the current folder pair if it has no history.
migrate_legacy_state() {
    [ -f "$STATE_ROOT/snapshot" ] || return 0
    [ -s "$SNAPSHOT" ] && return 0
    mv "$STATE_ROOT/snapshot" "$SNAPSHOT" || return 0
    local f
    for f in "$STATE_ROOT"/logs/*; do
        [ -e "$f" ] && mv "$f" "$LOG_DIR/"
    done
    if [ -d "$STATE_ROOT/trash" ]; then
        mkdir -p "$TRASH_DIR"
        for f in "$STATE_ROOT"/trash/*; do
            [ -e "$f" ] && mv "$f" "$TRASH_DIR/"
        done
        rmdir "$STATE_ROOT/trash" 2>/dev/null
    fi
    rmdir "$STATE_ROOT/logs" 2>/dev/null
    rm -f "$STATE_ROOT/local_manifest" "$STATE_ROOT/remote_manifest" \
          "$STATE_ROOT/snapshot.new" "$STATE_ROOT/conflicts.tmp"
    log "Moved sync history from an earlier version into $STATE_DIR"
}

# Forget the current pair's sync history (kept as snapshot.before-fresh-start),
# so the next sync behaves like a first sync: files on only one side are
# copied to the other side, and nothing is deleted.
start_fresh() {
    if [ -s "$SNAPSHOT" ]; then
        mv -f "$SNAPSHOT" "$SNAPSHOT.before-fresh-start"
    fi
    : > "$SNAPSHOT"
    log "Sync history cleared (start fresh); previous history kept as $SNAPSHOT.before-fresh-start"
}

# Deletion safety limit as text, e.g. "more than 50 files or 25%".
delete_limit_text() {
    local -a parts=()
    [ "$DELETE_CONFIRM_COUNT" -gt 0 ] && parts+=("more than $DELETE_CONFIRM_COUNT files")
    [ "$DELETE_CONFIRM_PERCENT" -gt 0 ] && parts+=("more than $DELETE_CONFIRM_PERCENT% of files")
    if [ "${#parts[@]}" -eq 0 ]; then
        echo "off"
    elif [ "${#parts[@]}" -eq 1 ]; then
        echo "${parts[0]}"
    else
        echo "${parts[0]} or ${parts[1]}"
    fi
}

# PROTON_SYNC_DRY_RUN=true forces every sync (menu or headless) to be a dry run.
FORCE_DRY_RUN="${PROTON_SYNC_DRY_RUN:-false}"
DRY_RUN="$FORCE_DRY_RUN"
# Skip the large-deletion confirmation (--allow-deletes).
ALLOW_DELETES="${PROTON_SYNC_ALLOW_DELETES:-false}"
DELETE_WARNING=false
# Set when the local folder is empty or missing although files were synced
# from it before (empty | missing); EMPTY_OK=true lets such a sync go ahead.
EMPTY_LOCAL=""
EMPTY_WARNING=false
EMPTY_OK=false

# pair_label INDEX — "~/Docs <> /docs"; the arrow shows the sync direction.
pair_label() {
    local arrow="<>"
    case "${PAIR_MODE[$1]}" in upload) arrow="->" ;; download) arrow="<-" ;; esac
    echo "$(display_path "${PAIR_LOCAL[$1]}") $arrow ${PAIR_REMOTE[$1]}"
}

pair_state_dir() {
    echo "$STATE_ROOT/pairs/$(pair_id "$1" "$2")"
}

# Last sync text for any pair (not just the current one).
pair_last_sync() {
    local f when text
    f="$(pair_state_dir "${PAIR_LOCAL[$1]}" "${PAIR_REMOTE[$1]}")/last_status"
    if [ -s "$f" ] && IFS=$'\t' read -r when text < "$f"; then
        echo "$(ago "$when"): $text"
    else
        echo "never synced"
    fi
}
