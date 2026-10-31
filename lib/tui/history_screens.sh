# ============================================================
# HISTORY AND LOG SCREENS
# ============================================================

logs_menu() {
    local -a items=()
    local f name result
    while IFS= read -r f; do
        name=$(basename "$f" .log)
        result=$(grep -m1 '^RESULT: ' "$f" 2>/dev/null | cut -c9-)
        [ -z "$result" ] && result="(no result recorded)"
        items+=("$f" "$(pretty_stamp "${name#sync-}")  $result")
    done < <(ls -1 "$LOG_DIR"/sync-*.log 2>/dev/null | sort -r | head -200)

    if [ "${#items[@]}" -eq 0 ]; then
        ui_msgbox "Sync History" "No syncs have run for this folder pair yet."
        return
    fi
    local choice="${items[0]}"
    while true; do
        choice=$(ui_menu "Sync History" "Newest first. Choose a sync to see its log." \
            "Back" "$choice" "${items[@]}") || return
        view_log "$choice"
    done
}

view_log() {
    local f="$1" choice view="$STATE_DIR/view.txt" name
    name=$(basename "$f" .log)
    choice=$(ui_menu "Log: $(pretty_stamp "${name#sync-}")" "What would you like to see?" "Back" "" \
        changes "Changes and problems only" \
        full    "Full log") || return
    if [ "$choice" = full ]; then
        ui_textbox "Full log: $(pretty_stamp "${name#sync-}")" "$f"
        return
    fi
    grep -E '^(RESULT:|=== Sync started|\[(UPLOAD|DOWNLOAD|MOVE|DELETED|CONFLICT|RESOLVE|ERROR|FATAL|STOPPED|RETRY|SKIP|CREATE))' \
        "$f" > "$view" 2>/dev/null
    [ -s "$view" ] || echo "No changes or problems in this sync." > "$view"
    ui_textbox "Changes and problems: $(pretty_stamp "${name#sync-}")" "$view"
    rm -f "$view"
}
