# ============================================================
# INSTALL / UNINSTALL
# ============================================================

INSTALL_PATH="$HOME/.local/bin/proton-drive-sync"
DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/proton-drive-sync.desktop"

install_script() {
    local kind
    mkdir -p "$(dirname "$INSTALL_PATH")" "$(dirname "$DESKTOP_FILE")" || return 1
    ln -sfn "$SCRIPT_PATH" "$INSTALL_PATH" || return 1
    cat > "$DESKTOP_FILE" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Proton Drive Sync
Comment=Sync folders with Proton Drive
Exec="$INSTALL_PATH"
Terminal=true
Icon=folder-remote
Categories=Utility;Network;FileTransfer;
DESKTOP
    echo "Installed: $INSTALL_PATH -> $SCRIPT_PATH"
    echo "Launcher:  $DESKTOP_FILE"

    # Point automatic sync at the installed command.
    kind=$(schedule_kind)
    case "$kind" in
        off|custom) ;;
        *)
            SCRIPT_PATH="$INSTALL_PATH"
            if apply_automatic_sync "$kind" >/dev/null; then
                echo "Automatic sync ($(schedule_text)) now runs $INSTALL_PATH."
            else
                echo "WARNING: couldn't update automatic sync; set it up again from the menu." >&2
            fi
            ;;
    esac
    case ":$PATH:" in
        *":$(dirname "$INSTALL_PATH"):"*) echo "Run it with: proton-drive-sync" ;;
        *) echo "Note: $(dirname "$INSTALL_PATH") isn't in your PATH; run it as $INSTALL_PATH" ;;
    esac
}

uninstall_script() {
    local kind
    kind=$(schedule_kind)
    if [ "$kind" != off ] && grep -qsF "$INSTALL_PATH" "$UNIT_DIR/$SERVICE_UNIT" "$UNIT_DIR/$WATCH_UNIT" \
        <(cron_entry); then
        remove_automatic_sync
        echo "Turned off automatic sync (it used $INSTALL_PATH)."
    fi
    rm -f "$INSTALL_PATH" "$DESKTOP_FILE"
    echo "Removed $INSTALL_PATH and the launcher."
    echo "Your settings ($CONFIG_FILE) and sync history ($STATE_ROOT) were kept."
}
