_deepest_first() {
    printf '%s\0' "$@" | sort -rz
}

_keep_folder() {
    log "[KEPT] folder: $1 (it holds items that aren't synced)"
    plan note "Kept $1/: it holds items that aren't synced"
    snap_folder "$1"
}

delete_local_folders() {
    [ "${#DEL_LOCAL_FOLDERS[@]}" -gt 0 ] || return 0
    local rel name local_path removable
    local -A deleted=()
    for rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        [ -n "${MOVED_FROM[$rel]+x}" ] || deleted["$rel"]=1
    done
    while IFS= read -r -d '' rel; do
        [ -n "$rel" ] || continue
        local_path="$LOCAL_DIR/$rel"
        [ -d "$local_path" ] || continue
        removable=true
        while IFS= read -r -d '' name; do
            [ -n "${deleted[$rel/$name]+x}" ] || { removable=false; break; }
        done < <(find "$local_path" -mindepth 1 -maxdepth 1 -printf '%f\0')
        if [ "$removable" = false ]; then
            _keep_folder "$rel"
            continue
        fi
        deleted["$rel"]=1
        log "[DELETED REMOTELY] folder: $rel -> removing local"
        plan del_local "$rel/ (folder)"
        if run rmdir "$local_path"; then
            COUNT_DELETED_LOCAL=$((COUNT_DELETED_LOCAL + 1))
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            plan failed "Removing local folder failed: $rel"
            snap_folder "$rel"
        fi
    done < <(_deepest_first "${DEL_LOCAL_FOLDERS[@]}")
}

trash_remote_folders() {
    [ "${#TRASH_REMOTE_FOLDERS[@]}" -gt 0 ] || return 0
    local rel name names removable
    local -A trashed=()
    for rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        [ -n "${MOVED_FROM[$rel]+x}" ] || [ -f "$LOCAL_DIR/$rel" ] || trashed["$rel"]=1
    done
    while IFS= read -r -d '' rel; do
        [ -n "$rel" ] || continue
        [ -d "$LOCAL_DIR/$rel" ] && continue
        if ! names=$(list_remote_entry_names "$REMOTE_DIR/$rel"); then
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            plan failed "Couldn't check folder on Proton before deleting it: $rel"
            snap_folder "$rel"
            continue
        fi
        removable=true
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            [ -n "${trashed[$rel/$name]+x}" ] || { removable=false; break; }
        done <<< "$names"
        if [ "$removable" = false ]; then
            _keep_folder "$rel"
            continue
        fi
        trashed["$rel"]=1
        log "[DELETED LOCALLY] folder: $rel -> trashing remote"
        plan del_remote "$rel/ (folder)"
        if trash_remote_path "$REMOTE_DIR/$rel"; then
            COUNT_TRASHED_REMOTE=$((COUNT_TRASHED_REMOTE + 1))
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            plan failed "Deleting folder on Proton failed: $rel"
            snap_folder "$rel"
        fi
    done < <(_deepest_first "${TRASH_REMOTE_FOLDERS[@]}")
}
