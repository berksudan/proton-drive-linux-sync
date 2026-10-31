# ============================================================
# RESTORE SCREENS
# ============================================================

restore_menu() {
    local -a items=()
    local d n
    while IFS= read -r d; do
        d="${d%/}"
        n=$(find "$d" -type f | wc -l)
        [ "$n" -eq 0 ] && continue
        items+=("$d" "$(pretty_stamp "$(basename "$d")")  $n file(s)")
    done < <(ls -1d "$TRASH_DIR"/*/ 2>/dev/null | sort -r)

    if [ "${#items[@]}" -eq 0 ]; then
        local keep="$TRASH_RETENTION_DAYS days"
        [ "$TRASH_RETENTION_DAYS" -eq 0 ] && keep="until you delete them"
        ui_msgbox "Restore Deleted Files" "There's nothing to restore.

When a sync deletes a local file (because it was deleted on Proton Drive), the file is kept here for $keep."
        return
    fi

    local session
    session=$(ui_menu "Restore Deleted Files" "Files deleted locally by each sync, newest first:" \
        "Back" "" "${items[@]}") || return

    local -a files=()
    mapfile -t files < <(cd "$session" && find . -type f | sed 's|^\./||' | sort)
    local count="${#files[@]}" action
    action=$(ui_menu "Restore: $(pretty_stamp "$(basename "$session")")" \
        "$count file(s) were deleted by this sync." "Back" "" \
        pick "Choose files to restore" \
        all  "Restore all $count files") || return

    local -a chosen=()
    if [ "$action" = all ]; then
        chosen=("${files[@]}")
    else
        local -a list=()
        local i picked
        for i in "${!files[@]}"; do
            list+=("$i" "${files[$i]}" off)
        done
        picked=$(ui_checklist "Restore Deleted Files" \
            "Select files with Space, then press Enter:" "${list[@]}") || return
        while IFS= read -r i; do
            [ -n "$i" ] && chosen+=("${files[$i]}")
        done <<< "$picked"
        [ "${#chosen[@]}" -eq 0 ] && return
    fi
    restore_files "$session" "${chosen[@]}"
}

# "dir/name.ext" -> "dir/name (restored).ext", "(restored 2)", ...
unique_restore_name() {
    local path="$1" dir name stem ext="" n=1 cand
    dir=$(dirname "$path"); name=$(basename "$path"); stem="${name%.*}"
    if [ -z "$stem" ] || [ "$stem" = "$name" ]; then
        stem="$name"
    else
        ext=".${name##*.}"
    fi
    while true; do
        if [ "$n" -eq 1 ]; then cand="$dir/$stem (restored)$ext"; else cand="$dir/$stem (restored $n)$ext"; fi
        [ -e "$cand" ] || { echo "$cand"; return; }
        n=$((n + 1))
    done
}

restore_files() {
    local session="$1"; shift
    local rel dest restored=0 failed=0 text
    local -a renamed=()
    for rel in "$@"; do
        dest="$LOCAL_DIR/$rel"
        if [ -e "$dest" ]; then
            dest=$(unique_restore_name "$dest")
            renamed+=("$rel -> ${dest#"$LOCAL_DIR"/}")
        fi
        if mkdir -p "$(dirname "$dest")" && mv "$session/$rel" "$dest"; then
            restored=$((restored + 1))
            log "[RESTORED] $rel -> $dest"
        else
            failed=$((failed + 1))
        fi
    done
    # Remove folders left empty in this trash session.
    find "$session" -depth -type d -empty -delete 2>/dev/null

    text="Restored $restored file(s) to $LOCAL_DIR. The next sync uploads them to Proton Drive again."
    if [ "${#renamed[@]}" -gt 0 ]; then
        text+=$'\n\nThese already existed, so the restored copies got new names:\n'
        text+="$(printf '  %s\n' "${renamed[@]:0:8}")"
        [ "${#renamed[@]}" -gt 8 ] && text+=$'\n'"  ...and $((${#renamed[@]} - 8)) more"
    fi
    [ "$failed" -gt 0 ] && text+=$'\n\n'"$failed file(s) couldn't be restored."
    ui_msgbox "Restore Complete" "$text"
}
