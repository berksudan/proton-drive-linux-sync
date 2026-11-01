# ============================================================
# FOLDER PAIR SCREENS
# ============================================================

paths_overlap() {
    [ "$1" = "$2" ] || [ "$1" = "/" ] || [ "$2" = "/" ] \
        || [[ "$1" == "$2"/* ]] || [[ "$2" == "$1"/* ]]
}

# overlap_warning INDEX LOCAL REMOTE — text describing another pair that
# overlaps these folders (INDEX is the pair being edited, or -1 for new).
overlap_warning() {
    local skip="$1" loc="$2" rem="$3" i
    for i in "${!PAIR_LOCAL[@]}"; do
        [ "$i" = "$skip" ] && continue
        if paths_overlap "$loc" "${PAIR_LOCAL[$i]}"; then
            echo "The local folder overlaps folder pair $((i + 1)) ($(pair_label "$i")), so the same files would be synced twice."
            return
        fi
        if paths_overlap "$rem" "${PAIR_REMOTE[$i]}"; then
            echo "The Proton folder overlaps folder pair $((i + 1)) ($(pair_label "$i")), so the same files would be synced twice."
            return
        fi
    done
}

# ask_local_folder DEFAULT — prints a checked absolute path.
ask_local_folder() {
    local value
    value=$(ui_input "Local Folder" "Folder on this computer to keep in sync:" "$1") || return 1
    value="${value/#\~/$HOME}"
    [ -z "$value" ] && return 1
    [[ "$value" = /* ]] || value="$PWD/$value"
    if [ ! -d "$value" ]; then
        ui_yesno "Local Folder" "$value doesn't exist. Create it?" "Create" "Cancel" || return 1
        if ! mkdir -p "$value"; then
            ui_msgbox "Local Folder" "Couldn't create $value."
            return 1
        fi
    fi
    strip_slash "$value"
}

# ask_remote_folder DEFAULT — prints a checked Proton path.
ask_remote_folder() {
    local value parent error
    value=$(ui_input "Proton Folder" "Folder on Proton Drive to keep in sync (starts with $PROTON_FILES_ROOT):" "$1") || return 1
    [ -z "$value" ] && return 1
    [[ "$value" = /* ]] || value="/$value"
    value=$(strip_slash "$value")
    if [ "$value" = / ]; then
        ui_msgbox "Proton Folder" "/ holds Proton Drive's top-level areas (your files, trash, photos and shared items), so it can't be synced. Choose a folder in $PROTON_FILES_ROOT."
        return 1
    fi
    ui_infobox "Proton Folder" "Checking $value on Proton Drive..."
    if proton_folder_exists "$value"; then
        echo "$value"
        return 0
    fi
    parent=$(dirname "$value")
    if ! proton_folder_exists "$parent"; then
        ui_msgbox "Proton Folder" "Neither $value nor its parent folder $parent exists on Proton Drive. Create the parent folder first, then try again."
        return 1
    fi
    ui_yesno "Proton Folder" "$value doesn't exist on Proton Drive. Create it?" "Create" "Cancel" || return 1
    if ! error=$(create_proton_folder "$value" 2>&1); then
        ui_msgbox "Proton Folder" "Couldn't create $value on Proton Drive:
$error"
        return 1
    fi
    echo "$value"
}

# ask_mode CURRENT — prints two-way | upload | download.
ask_mode() {
    ui_menu "Sync Mode" "How should these folders be kept in sync?" "Back" "$1" \
        two-way  "Two-way: changes and deletions go both ways" \
        upload   "Backup to Proton: upload only, never delete or download" \
        download "Download from Proton only: never upload or delete locally"
}

# Explain what happens on the first sync of a pair (or that history exists).
pair_history_note() {
    if [ -s "$(pair_state_dir "$1" "$2")/snapshot" ]; then
        echo "You've synced these folders together before, so their earlier history is used. Each folder pair keeps its own history, logs and trash."
    else
        echo "These folders haven't been synced together before. The first sync copies files that exist on only one side to the other side, and doesn't delete anything. Use Preview sync first to see what it will do."
    fi
}

pairs_menu() {
    if [ "$ENV_PAIR" = true ]; then
        ui_msgbox "Folder Pairs" "The folders are set by PROTON_SYNC_LOCAL_DIR / PROTON_SYNC_REMOTE_DIR for this run, so folder pairs can't be changed. Start the app without them to manage folder pairs."
        return
    fi
    local choice="$CURRENT_PAIR" i mark
    while true; do
        local -a items=()
        for i in "${!PAIR_LOCAL[@]}"; do
            mark="  "; [ "$i" = "$CURRENT_PAIR" ] && mark="* "
            items+=("$i" "$mark$((i + 1)). $(pair_label "$i")  ($(pair_last_sync "$i"))")
        done
        items+=(add "   Add a folder pair")
        choice=$(ui_menu "Folder Pairs" "Each pair keeps a local folder and a Proton Drive folder in sync. * marks the pair the menu is using. Automatic sync covers all pairs." \
            "Back" "$choice" "${items[@]}") || return
        if [ "$choice" = add ]; then
            add_pair
            choice="$CURRENT_PAIR"
        else
            pair_menu "$choice"
        fi
    done
}

add_pair() {
    local loc rem mode warn
    loc=$(ask_local_folder "$HOME/") || return
    rem=$(ask_remote_folder "$PROTON_FILES_ROOT/") || return
    mode=$(ask_mode two-way) || return
    warn=$(overlap_warning -1 "$loc" "$rem")
    if [ -n "$warn" ]; then
        ui_yesno "Overlapping Folders" "$warn

Add this folder pair anyway?" "Add anyway" "Cancel" || return
    fi
    PAIR_LOCAL+=("$loc"); PAIR_REMOTE+=("$rem"); PAIR_MODE+=("$mode"); PAIR_SKIP+=("")
    CFG_PAIR_LOCAL+=("$loc"); CFG_PAIR_REMOTE+=("$rem"); CFG_PAIR_MODE+=("$mode"); CFG_PAIR_SKIP+=("")
    save_config
    local n=$((${#PAIR_LOCAL[@]} - 1))
    if ui_yesno "Folder Pair Added" "Added folder pair $((n + 1)): $(pair_label "$n")

$(pair_history_note "$loc" "$rem")

Use this folder pair in the menu now?" "Use it" "Not now"; then
        select_pair "$n"
    fi
}

pair_menu() {
    local i="$1" choice=local value warn
    while true; do
        local -a items=()
        [ "$i" != "$CURRENT_PAIR" ] && items+=(use "Use this folder pair in the menu")
        local skip_text="none"
        [ -n "${PAIR_SKIP[$i]}" ] && skip_text="$(grep -c . <<< "${PAIR_SKIP[$i]}") folder(s)"
        items+=(local  "Local folder:     $(display_path "${PAIR_LOCAL[$i]}")"
                remote "Proton folder:    ${PAIR_REMOTE[$i]}"
                mode   "Sync mode:        $(mode_label "${PAIR_MODE[$i]}")"
                skip   "Skipped folders:  $skip_text"
                fresh  "Start fresh (forget this pair's sync history)"
                remove "Remove this folder pair")
        choice=$(ui_menu "Folder Pair $((i + 1))" "$(pair_label "$i")
Last sync: $(pair_last_sync "$i")" "Back" "$choice" "${items[@]}") || return
        case "$choice" in
            use)
                select_pair "$i"
                return
                ;;
            local|remote)
                if [ "$choice" = local ]; then
                    value=$(ask_local_folder "${PAIR_LOCAL[$i]}") || continue
                    [ "$value" = "${PAIR_LOCAL[$i]}" ] && continue
                    warn=$(overlap_warning "$i" "$value" "${PAIR_REMOTE[$i]}")
                else
                    value=$(ask_remote_folder "${PAIR_REMOTE[$i]}") || continue
                    [ "$value" = "${PAIR_REMOTE[$i]}" ] && continue
                    warn=$(overlap_warning "$i" "${PAIR_LOCAL[$i]}" "$value")
                fi
                if [ -n "$warn" ]; then
                    ui_yesno "Overlapping Folders" "$warn

Change it anyway?" "Change anyway" "Cancel" || continue
                fi
                if [ "$choice" = local ]; then
                    set_pair_field PAIR_LOCAL "$i" "$value"
                else
                    set_pair_field PAIR_REMOTE "$i" "$value"
                fi
                [ "$i" = "$CURRENT_PAIR" ] && select_pair "$i"
                ui_msgbox "Folders Changed" "$(pair_history_note "${PAIR_LOCAL[$i]}" "${PAIR_REMOTE[$i]}")"
                ;;
            mode)
                value=$(ask_mode "${PAIR_MODE[$i]}") || continue
                set_pair_field PAIR_MODE "$i" "$value"
                [ "$i" = "$CURRENT_PAIR" ] && select_pair "$i"
                ;;
            skip)
                skip_menu "$i"
                ;;
            fresh)
                ui_yesno "Start Fresh" "Forget the sync history for $(pair_label "$i")?

The next sync then works like a first sync: files that exist on only one side are copied to the other side, and nothing is deleted. Files you deleted on one side since the last sync will come back." "Start fresh" "Cancel" || continue
                local saved="$CURRENT_PAIR"
                select_pair "$i"
                start_fresh
                select_pair "$saved"
                ui_msgbox "Start Fresh" "Done. The next sync of this folder pair works like a first sync."
                ;;
            remove)
                if [ "${#PAIR_LOCAL[@]}" -eq 1 ]; then
                    ui_msgbox "Remove Folder Pair" "This is the only folder pair. Change its folders instead, or add another pair first."
                    continue
                fi
                ui_yesno "Remove Folder Pair" "Stop syncing $(pair_label "$i")?

No files are deleted, and its history is kept in case you add it again." "Remove" "Cancel" || continue
                remove_pair "$i"
                return
                ;;
        esac
    done
}

remove_pair() {
    local i="$1" key
    for key in PAIR_LOCAL PAIR_REMOTE PAIR_MODE PAIR_SKIP; do
        local -n _live="$key" _saved="CFG_$key"
        _live=("${_live[@]:0:$i}" "${_live[@]:$((i + 1))}")
        _saved=("${_saved[@]:0:$i}" "${_saved[@]:$((i + 1))}")
        unset -n _live _saved
    done
    local cur="$CURRENT_PAIR"
    if [ "$cur" -eq "$i" ]; then
        cur=0
    elif [ "$cur" -gt "$i" ]; then
        cur=$((cur - 1))
    fi
    select_pair "$cur"
    save_config
}

# Folders (or files) inside the pair that are never synced.
skip_menu() {
    local i="$1" choice value
    while true; do
        local -a items=() paths=()
        local p n=0
        while IFS= read -r p; do
            [ -n "$p" ] && { paths+=("$p"); items+=("$n" "Stop skipping: $p"); n=$((n + 1)); }
        done <<< "${PAIR_SKIP[$i]}"
        items+=(add "Add a folder to skip")
        choice=$(ui_menu "Skipped Folders" "These folders (and everything in them) are never synced in either direction, for $(pair_label "$i"). Paths are relative to the pair's folders; * and ? work as wildcards." \
            "Back" "" "${items[@]}") || return
        if [ "$choice" = add ]; then
            value=$(ui_input "Skip a Folder" "Folder to skip, relative to $(display_path "${PAIR_LOCAL[$i]}") (for example: Photos/2019):" "") || continue
            value="${value/#${PAIR_LOCAL[$i]}\//}"
            value="${value#/}"; value="${value%/}"
            [ -z "$value" ] && continue
            paths+=("$value")
        else
            paths=("${paths[@]:0:$choice}" "${paths[@]:$((choice + 1))}")
        fi
        set_pair_field PAIR_SKIP "$i" "$(printf '%s\n' "${paths[@]+"${paths[@]}"}" | sed '/^$/d')"
        [ "$i" = "$CURRENT_PAIR" ] && select_pair "$i"
    done
}
