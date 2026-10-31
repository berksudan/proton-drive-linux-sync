# ============================================================
# CONFLICT RESOLUTION
# ============================================================

resolve_keep_local() {
    local rel="$1"
    local local_path="$LOCAL_DIR/$rel"
    local remote_path="$REMOTE_DIR/$rel"
    log "[RESOLVE keep-local] $rel"
    if run_retry proton-drive filesystem upload -f replace "$local_path" "$(dirname "$remote_path")"; then
        COUNT_UPLOADED=$((COUNT_UPLOADED + 1))
        local lfp rfp
        lfp=$(get_local_fingerprint "$local_path")
        if [ "$DRY_RUN" = false ]; then
            rfp=$(fetch_remote_fingerprint "$remote_path")
        else
            rfp="${CONFLICT_REMOTE_FP[$rel]}"
        fi
        snap_file "${rel}" "${lfp}" "${rfp}"
    else
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
        plan failed "Upload failed (conflict): $rel"
        snap_file "${rel}" "${CONFLICT_PREV_L[$rel]}" "${CONFLICT_PREV_R[$rel]}"
    fi
}

resolve_keep_remote() {
    local rel="$1"
    local local_path="$LOCAL_DIR/$rel"
    local remote_path="$REMOTE_DIR/$rel"
    log "[RESOLVE keep-remote] $rel"
    ensure_local_folders "$(dirname "$local_path")"
    if run_retry proton-drive filesystem download -f remove "$remote_path" "$(dirname "$local_path")"; then
        COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
        local lfp
        if [ "$DRY_RUN" = false ]; then
            lfp=$(get_local_fingerprint "$local_path")
        else
            lfp="${CONFLICT_LOCAL_FP[$rel]}"
        fi
        snap_file "${rel}" "${lfp}" "${CONFLICT_REMOTE_FP[$rel]}"
    else
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
        plan failed "Download failed (conflict): $rel"
        snap_file "${rel}" "${CONFLICT_PREV_L[$rel]}" "${CONFLICT_PREV_R[$rel]}"
    fi
}

# Keep both: save the remote version beside the local file as a ".remote"
# copy, then upload the local file so both sides agree on the original name.
# The copy is uploaded as a new file on the next sync.
resolve_keep_both() {
    local rel="$1"
    local remote_path="$REMOTE_DIR/$rel"
    local dir name stem copy_name copy_rel n=1
    dir=$(dirname "$rel")
    name=$(basename "$rel")
    stem="${name%.*}"

    # Pick a name that doesn't exist yet: a.remote.txt, a.remote-2.txt, ...
    while true; do
        local tag=".remote"
        [ "$n" -gt 1 ] && tag=".remote-$n"
        if [ -z "$stem" ] || [ "$stem" = "$name" ]; then
            copy_name="${name}${tag}"
        else
            copy_name="${stem}${tag}.${name##*.}"
        fi
        if [ "$dir" = "." ]; then copy_rel="$copy_name"; else copy_rel="$dir/$copy_name"; fi
        [ -e "$LOCAL_DIR/$copy_rel" ] || break
        n=$((n + 1))
    done

    log "[RESOLVE keep-both] $rel -> saving remote version as $copy_rel"
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] download $remote_path -> $LOCAL_DIR/$copy_rel"
    else
        # Download into a scratch folder so the local file is never overwritten.
        local tmp
        tmp=$(mktemp -d "$STATE_DIR/download.XXXXXX")
        if ! retry proton-drive filesystem download "$remote_path" "$tmp" \
            || [ ! -f "$tmp/$name" ] \
            || ! mv "$tmp/$name" "$LOCAL_DIR/$copy_rel"; then
            rm -rf -- "${tmp:?}"
            log "[ERROR] Could not save remote copy of $rel; leaving conflict unresolved"
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            plan failed "Couldn't save the Proton copy (conflict): $rel"
            snap_file "$rel" "${CONFLICT_PREV_L[$rel]}" "${CONFLICT_PREV_R[$rel]}"
            return
        fi
        rm -rf -- "${tmp:?}"
        COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
    fi

    resolve_keep_local "$rel"
}

apply_conflict_resolution() {
    local rel="$1"
    local strategy="$2"
    case "$strategy" in
        local)  resolve_keep_local "$rel" ;;
        remote) resolve_keep_remote "$rel" ;;
        both)   resolve_keep_both "$rel" ;;
        skip)
            log "[RESOLVE skip] $rel — leaving unresolved"
            snap_file "${rel}" "${CONFLICT_PREV_L[$rel]}" "${CONFLICT_PREV_R[$rel]}"
            ;;
    esac
}

resolve_all_conflicts() {
    local count="${#CONFLICTS[@]}"
    [ "$count" -eq 0 ] && return

    log "=== Resolving $count conflict(s) ==="

    if [ "$CONFLICT_STRATEGY" != "ask" ]; then
        local rel
        for rel in "${CONFLICTS[@]}"; do
            apply_conflict_resolution "$rel" "$CONFLICT_STRATEGY"
        done
        return
    fi

    local bulk=""
    local rel choice
    for rel in "${CONFLICTS[@]}"; do
        if [ -n "$bulk" ]; then
            apply_conflict_resolution "$rel" "$bulk"
            continue
        fi

        resolve_conflict_interactive "$rel"
        choice="$CONFLICT_CHOICE"

        case "$choice" in
            alllocal)
                bulk="local"
                apply_conflict_resolution "$rel" "local"
                ;;
            allremote)
                bulk="remote"
                apply_conflict_resolution "$rel" "remote"
                ;;
            local|remote|both|skip)
                apply_conflict_resolution "$rel" "$choice"
                ;;
            *)
                apply_conflict_resolution "$rel" "skip"
                ;;
        esac
    done
}
