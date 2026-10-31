schedule_menu() {
    local have_systemd=false have_cron=false
    systemd_available && have_systemd=true
    cron_available && have_cron=true
    if [ "$have_systemd" = false ] && [ "$have_cron" = false ]; then
        ui_msgbox "Automatic Sync" "Automatic sync needs a systemd user session or cron, and neither is available.

Install cron (for example: sudo apt install cron), or run \"$(basename "$SCRIPT_PATH") --watch\" yourself when you log in."
        return
    fi
    local -a items=(
        hourly "Every hour"
        six    "Every 6 hours"
        daily  "Once a day (around 3 AM)")
    if [ "$have_systemd" = true ]; then
        items+=(watch "Continuously (sync local changes within seconds)")
    fi
    items+=(off "Turn off")
    local current backend choice used note=""
    current=$(schedule_text); backend=$(schedule_backend)
    [ -n "$backend" ] && current+=" (using $backend)"
    choice=$(ui_menu "Automatic Sync" "Syncs all your folder pairs in the background with your saved settings, even when this menu is closed.

Currently: $current" "Back" "$(schedule_kind)" "${items[@]}") || return

    if [ "$choice" = watch ] && ! command -v inotifywait >/dev/null 2>&1; then
        ui_msgbox "Automatic Sync" "Continuous sync needs inotifywait, which isn't installed.

Install it (for example: sudo apt install inotify-tools), then try again."
        return
    fi
    if ! used=$(apply_automatic_sync "$choice"); then
        ui_msgbox "Automatic Sync" "Couldn't set up automatic sync. Check that systemd or cron is working for your user."
        return
    fi
    if [ "$choice" = off ]; then
        ui_msgbox "Automatic Sync" "Automatic sync is off."
        return
    fi

    local where="Each run's output is added to:
  $STATE_ROOT/cron.log"
    if [ "$used" = systemd ]; then
        where="See each run's output with:
  journalctl --user -u ${WATCH_UNIT%.service} -u ${SERVICE_UNIT%.service}"
        if command -v loginctl >/dev/null 2>&1 \
            && [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
            note+=$'\n\n'"It runs while you're logged in. To keep syncing after you log out, run: loginctl enable-linger"
        fi
    fi
    [ "$choice" = watch ] && note+=$'\n\n'"Local changes are synced a few seconds after you stop editing. Proton Drive is checked every $WATCH_POLL_MINUTES minutes (change this in Settings)."
    [ "$CONFLICT_STRATEGY" = ask ] && note+=$'\n\n'"Conflicts are set to \"Ask me\", so background syncs skip files that changed on both sides until you sync from this menu. You can change that in Settings."
    ui_msgbox "Automatic Sync" "Automatic sync is on: $(schedule_text), using $used.

Results show up under Last sync on the main menu and in Sync history. $where

If a run would delete more files than your safety limit, it stops without changing anything; run a sync from this menu to confirm.$note"
}
