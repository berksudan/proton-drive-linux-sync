# ============================================================
# ACCOUNT SCREEN
# ============================================================

account_action() {
    if [ "$AUTH_STATE" = out ]; then
        perform_login
        if is_authenticated; then
            AUTH_STATE=in
            ui_msgbox "Logged In" "You're logged in to Proton Drive."
        else
            ui_msgbox "Not Logged In" "The login didn't complete. You can try again from the main menu."
        fi
    elif ui_yesno "Log Out" "Log out of Proton Drive?

Syncs, including automatic ones, won't work until you log in again." "Log out" "Cancel"; then
        proton-drive auth logout >/dev/null 2>&1
        AUTH_STATE=out
        ui_msgbox "Logged Out" "You've been logged out of Proton Drive."
    fi
}
