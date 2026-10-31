# ============================================================
# CONFLICT SCREENS
# ============================================================

# Ask how to resolve one conflict; sets CONFLICT_CHOICE. (Not echoed: the
# follow-up dialogs must draw on the terminal, so this can't run in $(...).)
resolve_conflict_interactive() {
    local rel="$1" local_desc remote_desc
    local_desc=$(fmt_fp "${CONFLICT_LOCAL_FP[$rel]}")
    remote_desc=$(fmt_fp "${CONFLICT_REMOTE_FP[$rel]}")
    local default=local
    while true; do
        CONFLICT_CHOICE=$(ui_menu "Conflict: $rel" \
"This file changed both here and on Proton Drive since the last sync.

  Local:  $local_desc
  Proton: $remote_desc

What would you like to do?" "" "$default" \
            diff      "Show differences" \
            local     "Keep LOCAL  (upload, replace the Proton version)" \
            remote    "Keep PROTON (download, replace the local version)" \
            both      "Keep BOTH   (local wins; Proton version saved as .remote copy)" \
            skip      "Skip        (decide next time)" \
            alllocal  "Keep LOCAL for all remaining conflicts" \
            allremote "Keep PROTON for all remaining conflicts") || CONFLICT_CHOICE=skip
        [ "$CONFLICT_CHOICE" = diff ] || return 0
        show_conflict_diff "$rel" "$local_desc" "$remote_desc"
        default=diff
    done
}

show_conflict_diff() {
    local rel="$1" local_desc="$2" remote_desc="$3" name tmp
    name=$(basename "$rel")
    tmp=$(mktemp -d "$STATE_DIR/diff.XXXXXX") || return
    mkdir "$tmp/remote"
    ui_infobox "Conflict: $rel" "Downloading the Proton version to compare..."
    if ! proton-drive filesystem download "$REMOTE_DIR/$rel" "$tmp/remote" >>"$LOG_FILE" 2>&1 \
        || [ ! -f "$tmp/remote/$name" ]; then
        ui_msgbox "Conflict: $rel" "Couldn't download the Proton version to compare. Details are in the log."
    elif is_text_file "$LOCAL_DIR/$rel" && is_text_file "$tmp/remote/$name"; then
        if diff -u --label "Local: $rel" --label "Proton: $rel" \
            "$LOCAL_DIR/$rel" "$tmp/remote/$name" > "$tmp/diff.txt"; then
            ui_msgbox "Conflict: $rel" "Both versions have exactly the same contents; only their timestamps differ. Keeping either one is safe."
        else
            ui_textbox "Differences (- local, + Proton): $rel" "$tmp/diff.txt"
        fi
    else
        ui_msgbox "Conflict: $rel" "These aren't text files, so they can't be compared line by line.

  Local:  $local_desc
  Proton: $remote_desc"
    fi
    rm -rf -- "${tmp:?}"
}
