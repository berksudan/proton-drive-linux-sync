# ============================================================
# MAIN MENU
# ============================================================

menu_header() {
    local account="logged in" n
    [ "$AUTH_STATE" = out ] && account="not logged in"
    n=$(pair_count)
    printf 'Folders:    %s' "$(pair_label "$CURRENT_PAIR")"
    [ "$n" -gt 1 ] && printf '   (pair %d of %d)' "$((CURRENT_PAIR + 1))" "$n"
    printf '\n'
    printf 'Mode:       %s\n' "$(mode_label "$SYNC_MODE")"
    printf 'Last sync:  %s\n' "$(last_sync_text)"
    printf 'Account:    %s    Conflicts: %s' "$account" "$(conflict_label)"
    [ "$FORCE_DRY_RUN" = true ] && printf '\n\nPreview only: PROTON_SYNC_DRY_RUN is set, so syncs make no changes.'
    return 0
}

main_menu() {
    local choice=sync account_item
    while true; do
        if [ "$AUTH_STATE" = out ]; then
            account_item="Log in to Proton Drive"
        else
            account_item="Log out of Proton Drive"
        fi
        local -a items=(sync "Sync now")
        [ "$(pair_count)" -gt 1 ] && items+=(syncall "Sync all $(pair_count) folder pairs")
        items+=(preview  "Preview sync (see what would change)"
                restore  "Restore deleted files"
                logs     "Sync history and logs"
                pairs    "Folder pairs ($(pair_count))"
                settings "Settings"
                schedule "Automatic sync: $(schedule_text)"
                account  "$account_item")
        choice=$(ui_menu "Main Menu" "$(menu_header)" "Quit" "$choice" "${items[@]}") || break
        case "$choice" in
            sync)     run_sync_with_gauge false ;;
            syncall)  sync_all_pairs ;;
            preview)  run_sync_with_gauge true ;;
            restore)  restore_menu ;;
            logs)     logs_menu ;;
            pairs)    pairs_menu ;;
            settings) settings_menu ;;
            schedule) schedule_menu ;;
            account)  account_action ;;
        esac
    done
    clear
    echo "Goodbye."
}

# Sync every folder pair in turn, then show one combined result.
sync_all_pairs() {
    local i saved="$CURRENT_PAIR" n text=""
    n=$(pair_count)
    for i in "${!PAIR_LOCAL[@]}"; do
        select_pair "$i"
        SYNC_TITLE="Syncing $((i + 1)) of $n: $(pair_label "$i")"
        LAST_RESULT="not run"
        run_sync_with_gauge false quiet
        text+="$((i + 1)). $(pair_label "$i")"$'\n'"   $LAST_RESULT"$'\n\n'
    done
    SYNC_TITLE=""
    select_pair "$saved"
    ui_msgbox "Sync All" "${text%$'\n\n'}"
}
