# ============================================================
# CORE SYNC ENGINE
# ============================================================

sync_engine() {
    local conflict_dump="$1"
    : > "$NEW_SNAPSHOT"

    SNAPSHOT_LOCAL_FP=(); SNAPSHOT_REMOTE_FP=(); SNAPSHOT_SEEN=()
    LOCAL_ITEMS=(); REMOTE_ITEMS=(); KNOWN_DIRS=()
    NEW_LOCAL_FILES=(); NEW_REMOTE_FILES=(); DELETED_REMOTELY_FILES=()
    TRASH_REMOTE_FILES=(); DEL_LOCAL_FOLDERS=(); TRASH_REMOTE_FOLDERS=()
    NEW_LOCAL_FP=(); NEW_REMOTE_FP=()
    CONFLICTS=(); CONFLICT_LOCAL_FP=(); CONFLICT_REMOTE_FP=()
    CONFLICT_PREV_L=(); CONFLICT_PREV_R=()
    JOB_QUEUE=(); JOB_LFP=(); JOB_RFP=(); JOB_PREV_L=(); JOB_PREV_R=()
    NOT_SYNCED=(); NOT_SYNCED_CARRY=(); PROTON_DOCS=()
    local -a REUPLOAD=() REDOWNLOAD=()
    ABORT_REASON=""
    DELETE_WARNING=false
    EMPTY_LOCAL=""
    EMPTY_WARNING=false
    : > "$PLAN_FILE"
    rm -f "$PENDING_DELETES"
    COUNT_OK=0; COUNT_UPLOADED=0; COUNT_DOWNLOADED=0
    COUNT_MOVED_REMOTE=0; COUNT_MOVED_LOCAL=0
    COUNT_DELETED_LOCAL=0; COUNT_TRASHED_REMOTE=0
    COUNT_CONFLICTS=0; COUNT_ERRORS=0; COUNT_FIRST_SYNC=0

    log "=== Sync started $(date) ==="
    log "Local:  $LOCAL_DIR"
    log "Proton: $REMOTE_DIR"
    log "Mode:   $(mode_label "$SYNC_MODE")"
    [ "$DRY_RUN" = true ] && log "=== DRY RUN MODE ==="

    gauge 2 "Scanning local files..."
    # One find pass collects type, size and mtime for every local item
    # (instead of a stat per file) and skips excluded names without
    # descending into them. Records are "path<TAB>type size mtime".
    local -a prune=()
    local pattern
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        prune+=(-name "$pattern" -o)
    done
    local -a skip_excluded=()
    if [ "${#prune[@]}" -gt 0 ]; then
        unset 'prune[${#prune[@]}-1]'
        skip_excluded=(\( "${prune[@]}" \) -prune -o)
    fi
    local rec meta ftype fsize fmtime max_bytes=$((MAX_FILE_SIZE_MB * 1048576))
    [ -d "$LOCAL_DIR" ] || EMPTY_LOCAL=missing
    find "$LOCAL_DIR" -mindepth 1 "${skip_excluded[@]}" \
        -printf '%P\t%Y %s %T@\0' | sort -z | \
        while IFS= read -r -d '' rec; do
            rel="${rec%$'\t'*}"
            meta="${rec##*$'\t'}"
            if [[ "$rel" == *$'\n'* ]]; then
                log "[SKIP] local name contains a line break: ${rel//$'\n'/\\n}"
                continue
            fi
            ftype="${meta%% *}"; meta="${meta#* }"
            fsize="${meta%% *}"; fmtime="${meta#* }"; fmtime="${fmtime%.*}"
            [ "${#SKIP_PATHS[@]}" -gt 0 ] && is_skipped_path "$rel" && continue
            if [ "$ftype" = f ] && [ "$max_bytes" -gt 0 ] && [ "$fsize" -gt "$max_bytes" ]; then
                log "[SKIP TOO LARGE] local: $rel ($fsize bytes)"
                printf 'big%s%s\n' "$SEP" "$rel"
                continue
            fi
            case "$ftype" in
                d) printf 'folder%s%s\n' "$SEP" "$rel" ;;
                f) printf 'file%s%s%s%s%s%s\n' "$SEP" "$rel" "$SEP" "$fsize" "$SEP" "$fmtime" ;;
            esac
        done > "$LOCAL_MANIFEST" 2>/dev/null

    gauge 5 "Listing folders on Proton Drive..."
    if ! list_remote_tree > "$REMOTE_MANIFEST.unsorted"; then
        rm -f "$REMOTE_MANIFEST.unsorted"
        ABORT_REASON="Could not list one or more remote folders (see log). Stopped so their files aren't treated as deleted."
        log "[FATAL] $ABORT_REASON"
        gauge 100 "Stopped: a Proton folder couldn't be listed"
        return 1
    fi
    sort "$REMOTE_MANIFEST.unsorted" > "$REMOTE_MANIFEST"
    rm -f "$REMOTE_MANIFEST.unsorted"

    if ! check_remote_manifest_sane; then
        ABORT_REASON="Remote listing came back empty but sync history exists. If the remote really is empty, remove $SNAPSHOT to reset."
        log "[FATAL] $ABORT_REASON"
        gauge 100 "Stopped: unsafe remote state"
        return 1
    fi

    load_snapshot

    # ---------- Empty or missing local folder ----------
    # If files were synced from this folder before and it's now empty or
    # gone (a drive that isn't mounted, a new computer), a two-way sync
    # would delete everything on Proton, and a download-only one would fill
    # the empty folder. Stop and let the user decide. Backup-only pairs
    # never delete on Proton, so they carry on.
    if [ "${#SNAPSHOT_LOCAL_FP[@]}" -gt 0 ] && [ "$SYNC_MODE" != upload ] && [ "$EMPTY_OK" != true ]; then
        if [ -z "$EMPTY_LOCAL" ] && ! grep -q "^file$SEP" "$LOCAL_MANIFEST"; then
            EMPTY_LOCAL=empty
        fi
        if [ -n "$EMPTY_LOCAL" ]; then
            ABORT_REASON="The local folder $LOCAL_DIR is $EMPTY_LOCAL, but ${#SNAPSHOT_LOCAL_FP[@]} files were synced from it before."
            if [ "$DRY_RUN" = true ]; then
                EMPTY_WARNING=true
            else
                log "[STOPPED] $ABORT_REASON"
                gauge 100 "Stopped: the local folder is $EMPTY_LOCAL"
                return 4
            fi
        fi
    else
        EMPTY_LOCAL=""
    fi

    load_manifests_to_memory
    build_remote_dir_cache

    # Progress: comparing takes 10-40% of the bar, transfers 45-95%.
    local compare_total compare_done=0
    compare_total=$(( $(wc -l < "$LOCAL_MANIFEST") + $(wc -l < "$REMOTE_MANIFEST") ))
    [ "$compare_total" -eq 0 ] && compare_total=1

    # ---------- PHASE 2: local items ----------
    while IFS="$SEP" read -r type rel lsize lmtime; do
        compare_done=$((compare_done + 1))
        (( compare_done % 50 == 0 )) && gauge $((10 + 30 * compare_done / compare_total)) \
            "Comparing files ($compare_done of $compare_total)..."
        remote_path="$REMOTE_DIR/$rel"
        local_path="$LOCAL_DIR/$rel"

        if [ "$type" = "folder" ]; then
            if [ -n "${REMOTE_ITEMS[folder|${rel}]+x}" ]; then
                log "[OK] folder: $rel"
                snap_folder "$rel"
            elif [ "$SYNC_MODE" = download ]; then
                continue    # never create folders on Proton
            elif was_previously_synced "$rel" && [ "$SYNC_MODE" = two-way ]; then
                DEL_LOCAL_FOLDERS+=("$rel")
            else
                remote_dir_exists "$rel" || plan folder "On Proton: $rel"
                ensure_remote_folders "$rel"
                snap_folder "$rel"
            fi

        elif [ "$type" = "file" ]; then
            [ -f "$local_path" ] || continue
            [ -n "${NOT_SYNCED[$rel]+x}" ] && continue
            local local_fp="${lsize}|${lmtime}"
            local prev_local_fp="${SNAPSHOT_LOCAL_FP[$rel]:-}"
            local prev_remote_fp="${SNAPSHOT_REMOTE_FP[$rel]:-}"

            if [ -n "${REMOTE_ITEMS[file|${rel}]+x}" ]; then
                local remote_fp="${REMOTE_ITEMS[file|${rel}]}"
                local local_changed=false remote_changed=false
                [ -n "$prev_local_fp" ] && [ "$prev_local_fp" != "$local_fp" ] && local_changed=true
                [ -n "$prev_remote_fp" ] && [ "$prev_remote_fp" != "$remote_fp" ] && remote_changed=true
                debug "$rel: local $local_fp (was ${prev_local_fp:-none}), Proton $remote_fp (was ${prev_remote_fp:-none})"

                if [ -z "$prev_local_fp" ] || [ -z "$prev_remote_fp" ]; then
                    log "[FIRST SYNC] $rel"
                    COUNT_FIRST_SYNC=$((COUNT_FIRST_SYNC + 1))
                    snap_file "${rel}" "${local_fp}" "${remote_fp}"
                elif [ "$local_changed" = false ] && [ "$remote_changed" = false ]; then
                    log "[OK] $rel"
                    COUNT_OK=$((COUNT_OK + 1))
                    snap_file "${rel}" "${local_fp}" "${remote_fp}"
                elif [ "$local_changed" = true ] && [ "$SYNC_MODE" = download ]; then
                    if [ "$remote_changed" = true ]; then
                        # Both changed: the Proton version wins, the local copy goes to the trash.
                        log "[DOWNLOAD MODIFIED] $rel (changed on both sides; local copy moved to trash)"
                        plan down "$rel (changed on both sides; local copy kept in the local trash)"
                        trash_local "$local_path" "$rel"
                        queue_job down_mod "$rel" "$local_fp" "$remote_fp" "$prev_local_fp" "$prev_remote_fp"
                    else
                        log "[IGNORED] $rel changed locally (download-only folder pair)"
                        snap_file "${rel}" "${local_fp}" "${remote_fp}"
                    fi
                elif [ "$remote_changed" = true ] && [ "$SYNC_MODE" = upload ]; then
                    if [ "$local_changed" = true ]; then
                        log "[UPLOAD MODIFIED] $rel (changed on both sides; local version kept)"
                        plan up "$rel (changed on both sides; local version kept)"
                        queue_job up_mod "$rel" "$local_fp" "$remote_fp" "$prev_local_fp" "$prev_remote_fp"
                    else
                        log "[IGNORED] $rel changed on Proton (backup-only folder pair)"
                        snap_file "${rel}" "${local_fp}" "${remote_fp}"
                    fi
                elif [ "$local_changed" = true ] && [ "$remote_changed" = false ]; then
                    log "[UPLOAD MODIFIED] $rel"
                    plan up "$rel (changed)"
                    queue_job up_mod "$rel" "$local_fp" "$remote_fp" "$prev_local_fp" "$prev_remote_fp"
                elif [ "$local_changed" = false ] && [ "$remote_changed" = true ]; then
                    log "[DOWNLOAD MODIFIED] $rel"
                    plan down "$rel (changed)"
                    queue_job down_mod "$rel" "$local_fp" "$remote_fp" "$prev_local_fp" "$prev_remote_fp"
                else
                    log "[CONFLICT] $rel"
                    plan conflict "$rel ($(conflict_note))"
                    COUNT_CONFLICTS=$((COUNT_CONFLICTS + 1))
                    printf '%s\n' "${rel}${SEP}${local_fp}${SEP}${remote_fp}${SEP}${prev_local_fp}${SEP}${prev_remote_fp}" \
                        >> "$conflict_dump"
                fi
            elif was_previously_synced "$rel"; then
                if [ "$SYNC_MODE" = upload ]; then
                    # Missing on Proton: back it up again.
                    REUPLOAD+=("$rel")
                    NEW_LOCAL_FP["$rel"]="$local_fp"
                else
                    # Two-way: deleted on Proton. Download-only: kept locally,
                    # but still considered for local move detection.
                    DELETED_REMOTELY_FILES+=("$rel")
                fi
            elif [ "$SYNC_MODE" != download ]; then
                NEW_LOCAL_FILES+=("$rel")
                NEW_LOCAL_FP["$rel"]="$local_fp"
            fi
        fi
    done < "$LOCAL_MANIFEST"

    # ---------- PHASE 3: remote-only items ----------
    while IFS="$SEP" read -r type rel size mtime; do
        compare_done=$((compare_done + 1))
        (( compare_done % 50 == 0 )) && gauge $((10 + 30 * compare_done / compare_total)) \
            "Comparing files ($compare_done of $compare_total)..."
        local_path="$LOCAL_DIR/$rel"
        [ -n "${LOCAL_ITEMS[${type}|${rel}]:-}" ] && continue

        if [ "$type" = "folder" ]; then
            if [ -d "$local_path" ]; then
                snap_folder "$rel"
                continue
            fi
            [ "$SYNC_MODE" = upload ] && continue    # never create local folders
            if was_previously_synced "$rel" && [ "$SYNC_MODE" = two-way ]; then
                TRASH_REMOTE_FOLDERS+=("$rel")
            else
                log "[DOWNLOAD NEW FOLDER] $rel"
                plan folder "Local: $rel"
                ensure_local_folders "$local_path"
                snap_folder "$rel"
            fi
        elif [ "$type" = "file" ]; then
            [ -f "$local_path" ] && continue
            [ -n "${NOT_SYNCED[$rel]+x}" ] && continue
            if was_previously_synced "$rel"; then
                if [ "$SYNC_MODE" = download ]; then
                    # Missing locally: download it again.
                    REDOWNLOAD+=("$rel")
                    NEW_REMOTE_FP["$rel"]="${size}|${mtime}"
                else
                    # Two-way: deleted locally. Backup-only: kept on Proton,
                    # but still considered for move detection.
                    TRASH_REMOTE_FILES+=("$rel")
                fi
            elif [ "$SYNC_MODE" != upload ]; then
                NEW_REMOTE_FILES+=("$rel")
                NEW_REMOTE_FP["$rel"]="${size}|${mtime}"
            fi
        fi
    done < "$REMOTE_MANIFEST"

    # Files skipped for size keep their previous history, so they aren't
    # treated as new or deleted if they shrink back under the limit.
    for rel in "${!NOT_SYNCED[@]}"; do
        plan skipped "$rel (${NOT_SYNCED[$rel]})"
        if [ -n "${NOT_SYNCED_CARRY[$rel]+x}" ] && [ -n "${SNAPSHOT_LOCAL_FP[$rel]+x}" ]; then
            snap_file "$rel" "${SNAPSHOT_LOCAL_FP[$rel]}" "${SNAPSHOT_REMOTE_FP[$rel]}"
        fi
    done

    # ---------- PHASE 4: move detection ----------
    # A file counts as moved only when its size+mtime fingerprint is unique
    # on both sides; otherwise identical copies could be matched to the
    # wrong file. Unmatched files fall through to plain upload/download/delete.
    gauge 40 "Detecting moved files..."
    local old_rel new_rel fp match spec
    declare -A OLD_FP_COUNT=() NEW_FP_COUNT=() FP_TO_OLD=() MOVED_FROM=() MOVE_SRC=()
    declare -a REMOTE_MOVES=() LOCAL_MOVES=()

    for old_rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        fp="${SNAPSHOT_LOCAL_FP[$old_rel]:-}"
        { [ -z "$fp" ] || [ "$fp" = "0|0" ]; } && continue
        OLD_FP_COUNT["$fp"]=$(( ${OLD_FP_COUNT[$fp]:-0} + 1 ))
        FP_TO_OLD["$fp"]="$old_rel"
    done
    for new_rel in "${NEW_LOCAL_FILES[@]+"${NEW_LOCAL_FILES[@]}"}"; do
        fp="${NEW_LOCAL_FP[$new_rel]}"
        NEW_FP_COUNT["$fp"]=$(( ${NEW_FP_COUNT[$fp]:-0} + 1 ))
    done
    declare -a REMAINING_NEW_LOCAL=()
    for new_rel in "${NEW_LOCAL_FILES[@]+"${NEW_LOCAL_FILES[@]}"}"; do
        fp="${NEW_LOCAL_FP[$new_rel]}"
        if [ "${OLD_FP_COUNT[$fp]:-0}" -eq 1 ] && [ "${NEW_FP_COUNT[$fp]:-0}" -eq 1 ]; then
            match="${FP_TO_OLD[$fp]}"
            REMOTE_MOVES+=("${match}${SEP}${new_rel}")
            MOVE_SRC["$match"]=1
        else
            REMAINING_NEW_LOCAL+=("$new_rel")
        fi
    done

    OLD_FP_COUNT=(); NEW_FP_COUNT=(); FP_TO_OLD=()
    for old_rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        fp="${SNAPSHOT_REMOTE_FP[$old_rel]:-}"
        { [ -z "$fp" ] || [ "$fp" = "0|0" ]; } && continue
        OLD_FP_COUNT["$fp"]=$(( ${OLD_FP_COUNT[$fp]:-0} + 1 ))
        FP_TO_OLD["$fp"]="$old_rel"
    done
    for new_rel in "${NEW_REMOTE_FILES[@]+"${NEW_REMOTE_FILES[@]}"}"; do
        fp="${NEW_REMOTE_FP[$new_rel]}"
        NEW_FP_COUNT["$fp"]=$(( ${NEW_FP_COUNT[$fp]:-0} + 1 ))
    done
    declare -a REMAINING_NEW_REMOTE=()
    for new_rel in "${NEW_REMOTE_FILES[@]+"${NEW_REMOTE_FILES[@]}"}"; do
        fp="${NEW_REMOTE_FP[$new_rel]}"
        match=""
        if [ "${OLD_FP_COUNT[$fp]:-0}" -eq 1 ] && [ "${NEW_FP_COUNT[$fp]:-0}" -eq 1 ]; then
            match="${FP_TO_OLD[$fp]}"
        fi
        if [ -n "$match" ] && [ -f "$LOCAL_DIR/$match" ]; then
            LOCAL_MOVES+=("${match}${SEP}${new_rel}")
            MOVE_SRC["$match"]=1
        else
            REMAINING_NEW_REMOTE+=("$new_rel")
        fi
    done

    REMAINING_NEW_LOCAL+=("${REUPLOAD[@]+"${REUPLOAD[@]}"}")
    REMAINING_NEW_REMOTE+=("${REDOWNLOAD[@]+"${REDOWNLOAD[@]}"}")

    # ---------- Deletion safety check ----------
    # Runs before any file is moved, transferred or deleted. One-way folder
    # pairs never delete files.
    local -a deletions=()
    if [ "$SYNC_MODE" = two-way ]; then
        for rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
            [ -n "${MOVE_SRC[$rel]+x}" ] && continue
            [ -f "$LOCAL_DIR/$rel" ] && deletions+=("Local (to local trash):   $rel")
        done
        for rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
            [ -n "${MOVE_SRC[$rel]+x}" ] && continue
            [ -f "$LOCAL_DIR/$rel" ] || deletions+=("Proton (to Proton trash): $rel")
        done
    fi
    if [ "$ALLOW_DELETES" != true ] && deletions_exceed_limit "${#deletions[@]}"; then
        if [ "$DRY_RUN" = true ]; then
            DELETE_WARNING=true
        else
            printf '%s\n' "${deletions[@]}" > "$PENDING_DELETES"
            ABORT_REASON="This sync would delete ${#deletions[@]} files, more than the safety limit ($(delete_limit_text))."
            log "[STOPPED] $ABORT_REASON"
            gauge 100 "Stopped: ${#deletions[@]} files would be deleted"
            return 2
        fi
    fi

    # ---------- Execute moves ----------
    for spec in "${REMOTE_MOVES[@]+"${REMOTE_MOVES[@]}"}"; do
        match="${spec%%"$SEP"*}"; new_rel="${spec#*"$SEP"}"
        fp="${NEW_LOCAL_FP[$new_rel]}"
        log "[MOVE REMOTE] $match -> $new_rel"
        plan move "On Proton: $match -> $new_rel"
        if do_remote_move "$match" "$new_rel"; then
            COUNT_MOVED_REMOTE=$((COUNT_MOVED_REMOTE + 1))
            snap_file "$new_rel" "$fp" "${SNAPSHOT_REMOTE_FP[$match]:-}"
            MOVED_FROM["$match"]=1
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            plan failed "Move on Proton failed: $match -> $new_rel"
            REMAINING_NEW_LOCAL+=("$new_rel")
            if [ "$REMOTE_MOVE_LANDED_REL" != "$match" ]; then
                MOVED_FROM["$match"]=1
                log "[DELETED LOCALLY] $REMOTE_MOVE_LANDED_REL (left by the failed move) -> trashing remote"
                queue_job trash "$REMOTE_MOVE_LANDED_REL" "" "" \
                    "${SNAPSHOT_LOCAL_FP[$match]:-}" "${SNAPSHOT_REMOTE_FP[$match]:-}"
            fi
        fi
    done
    for spec in "${LOCAL_MOVES[@]+"${LOCAL_MOVES[@]}"}"; do
        match="${spec%%"$SEP"*}"; new_rel="${spec#*"$SEP"}"
        fp="${NEW_REMOTE_FP[$new_rel]}"
        log "[MOVE LOCAL] $match -> $new_rel"
        plan move "Locally: $match -> $new_rel"
        ensure_local_folders "$(dirname "$LOCAL_DIR/$new_rel")"
        if run mv "$LOCAL_DIR/$match" "$LOCAL_DIR/$new_rel"; then
            COUNT_MOVED_LOCAL=$((COUNT_MOVED_LOCAL + 1))
            local lfp
            if [ "$DRY_RUN" = false ]; then lfp=$(get_local_fingerprint "$LOCAL_DIR/$new_rel"); else lfp="${SNAPSHOT_LOCAL_FP[$match]:-}"; fi
            snap_file "$new_rel" "$lfp" "$fp"
            MOVED_FROM["$match"]=1
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            plan failed "Local move failed: $match -> $new_rel"
            REMAINING_NEW_REMOTE+=("$new_rel")
        fi
    done

    # ---------- PHASE 5: remaining actions ----------
    for rel in "${REMAINING_NEW_LOCAL[@]+"${REMAINING_NEW_LOCAL[@]}"}"; do
        [ -z "$rel" ] && continue
        [ -f "$LOCAL_DIR/$rel" ] || continue
        log "[UPLOAD NEW] $rel"
        plan up "$rel"
        windows_unsafe "$rel" && plan note "Name can't be used on Windows: $rel"
        # Folder creation updates KNOWN_DIRS, so it stays serial.
        ensure_remote_folders "$(dirname "$rel")"
        queue_job up_new "$rel" "${NEW_LOCAL_FP[$rel]}" "" "" ""
    done

    for rel in "${REMAINING_NEW_REMOTE[@]+"${REMAINING_NEW_REMOTE[@]}"}"; do
        [ -z "$rel" ] && continue
        log "[DOWNLOAD NEW] $rel"
        plan down "$rel"
        ensure_local_folders "$(dirname "$LOCAL_DIR/$rel")"
        queue_job down_new "$rel" "" "${NEW_REMOTE_FP[$rel]}" "" ""
    done

    for rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        [ "$SYNC_MODE" = two-way ] || break
        [ -n "${MOVED_FROM[$rel]+x}" ] && continue
        [ -f "$LOCAL_DIR/$rel" ] && continue
        log "[DELETED LOCALLY] $rel -> trashing remote"
        plan del_remote "$rel"
        queue_job trash "$rel" "" "" "${SNAPSHOT_LOCAL_FP[$rel]:-}" "${SNAPSHOT_REMOTE_FP[$rel]:-}"
    done

    # Run every queued file transfer (modified and new files, remote
    # trashes) in parallel, then record the results.
    run_job_queue
    process_job_results

    for rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        [ "$SYNC_MODE" = two-way ] || break
        [ -n "${MOVED_FROM[$rel]+x}" ] && continue
        local_path="$LOCAL_DIR/$rel"; [ -f "$local_path" ] || continue
        log "[DELETED REMOTELY] $rel -> removing local"
        plan del_local "$rel"
        trash_local "$local_path" "$rel"
        COUNT_DELETED_LOCAL=$((COUNT_DELETED_LOCAL + 1))
    done

    delete_local_folders
    trash_remote_folders

    # ---------- Finalize (snapshot handled by caller) ----------
    gauge 97 "Finishing up..."
    rm -f "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"
    cleanup_old_trash
    cleanup_old_logs

    {
        echo "=== Scan/transfer summary (pre-conflict) ==="
        sync_summary | sed 's/^/  /'
        echo "=== Scan finished $(date) ==="
    } >> "$LOG_FILE"

    gauge 100 "Done"
    return 0
}

# ============================================================
# SYNC RUN HELPERS (shared by TUI and headless mode)
# ============================================================

load_conflicts() {
    local conflict_dump="$1"
    CONFLICTS=(); CONFLICT_LOCAL_FP=(); CONFLICT_REMOTE_FP=()
    CONFLICT_PREV_L=(); CONFLICT_PREV_R=()
    [ -s "$conflict_dump" ] || return 0
    local rel lfp rfp pl pr
    while IFS="$SEP" read -r rel lfp rfp pl pr; do
        CONFLICTS+=("$rel")
        CONFLICT_LOCAL_FP["$rel"]="$lfp"
        CONFLICT_REMOTE_FP["$rel"]="$rfp"
        CONFLICT_PREV_L["$rel"]="$pl"
        CONFLICT_PREV_R["$rel"]="$pr"
    done < "$conflict_dump"
}

finalize_snapshot() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Snapshot not updated."
        rm -f "$NEW_SNAPSHOT"
    else
        mv "$NEW_SNAPSHOT" "$SNAPSHOT" 2>/dev/null || true
    fi
}

sync_summary() {
    printf "%s\n" \
        "Unchanged:       $COUNT_OK" \
        "First sync:      $COUNT_FIRST_SYNC" \
        "Uploaded:        $COUNT_UPLOADED" \
        "Downloaded:      $COUNT_DOWNLOADED" \
        "Moved (remote):  $COUNT_MOVED_REMOTE" \
        "Moved (local):   $COUNT_MOVED_LOCAL" \
        "Deleted local:   $COUNT_DELETED_LOCAL" \
        "Trashed remote:  $COUNT_TRASHED_REMOTE" \
        "Conflicts:       $COUNT_CONFLICTS" \
        "Errors:          $COUNT_ERRORS"
    local n
    n=$(plan_count skipped)
    [ "$n" -gt 0 ] && echo "Not synced:      $n (Proton Docs or over the size limit; see Preview)"
    n=$(plan_count note)
    [ "$n" -gt 0 ] && echo "Notes:           $n (see Preview)"
    return 0
}
