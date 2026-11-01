# ============================================================
# REMOTE LISTING
# ============================================================

PROTON_ENTRY_NAME_JQ='(if .name | type == "object" then .name.value else .name end)'

# list_remote_dir PREFIX
# Print manifest lines for the direct children of $REMOTE_DIR/PREFIX:
#   folder<SEP>rel<SEP><SEP>   and   file<SEP>rel<SEP>size<SEP>mtime
# Returns 1 if the folder couldn't be listed after 3 attempts.
list_remote_dir() {
    local prefix="$1"
    local remote_path="$REMOTE_DIR" json="" attempt ok=false
    [ -n "$prefix" ] && remote_path="$REMOTE_DIR/$prefix"

    for attempt in 1 2 3; do
        if json=$(proton-drive filesystem list "$remote_path" -j 2>>"$LOG_FILE"); then
            ok=true
            break
        fi
        log "[RETRY $attempt/3] Could not list $remote_path"
        [ "$attempt" -lt 3 ] && sleep $((attempt * 2))
    done
    if [ "$ok" = false ]; then
        log "[ERROR] Giving up listing $remote_path"
        return 1
    fi

    # Timestamps in the usual "YYYY-MM-DDTHH:MM:SS[.fff]Z" form are converted
    # to epoch seconds here (prefixed "@"); anything else goes to `date -d`
    # below, exactly as before, so existing snapshots stay valid.
    printf '%s' "$json" | jq -r '
        .[] |
        (if .type | type == "object" then .type.value else .type end) as $type |
        '"$PROTON_ENTRY_NAME_JQ"' as $name |
        (if .mediaType | type == "object" then .mediaType.value else (.mediaType // "") end) as $media |
        (((.activeRevision.value // .activeRevision) | .claimedSize) // 0) as $size |
        (((.activeRevision.value // .activeRevision) | .claimedModificationTime) // "") as $mtime |
        (if ($mtime | type) == "string"
            and ($mtime | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))
         then "@" + ($mtime | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | floor | tostring)
         else $mtime end) as $mt |
        if ($name | test("\n")) then "skip\u001f\($name | gsub("\n"; "\\n"))"
        else "\($type)\u001f\($name)\u001f\($media)\u001f\($size)\u001f\($mt)" end
    ' | \
    while IFS="$SEP" read -r type name media size mtime; do
        local rel_path
        if [ -z "$prefix" ]; then
            rel_path="$name"
        else
            rel_path="$prefix/$name"
        fi

        if [ "$type" = "skip" ]; then
            log "[SKIP] remote name contains a line break: $rel_path"
            continue
        fi

        if is_excluded "$rel_path" || is_skipped_path "$rel_path"; then
            continue
        fi

        if [ "$type" = "folder" ]; then
            printf 'folder%s%s%s%s\n' "$SEP" "$rel_path" "$SEP" "$SEP"
        else
            if [ "$media" = "application/vnd.proton.doc" ]; then
                log "[SKIP PROTON DOC] $rel_path"
                printf 'doc%s%s\n' "$SEP" "$rel_path"
                continue
            fi
            if [ "$MAX_FILE_SIZE_MB" -gt 0 ] && [ "$size" -gt $((MAX_FILE_SIZE_MB * 1048576)) ]; then
                log "[SKIP TOO LARGE] Proton: $rel_path ($size bytes)"
                printf 'big%s%s\n' "$SEP" "$rel_path"
                continue
            fi
            local mtime_epoch=0
            if [[ "$mtime" == @* ]]; then
                mtime_epoch="${mtime#@}"
            elif [ -n "$mtime" ]; then
                mtime_epoch=$(date -d "$mtime" +%s 2>/dev/null || echo 0)
            fi
            printf 'file%s%s%s%s%s%s\n' "$SEP" "$rel_path" "$SEP" "$size" "$SEP" "$mtime_epoch"
        fi
    done
}

# list_remote_dirs OUT_DIR PREFIX...
# List several remote folders in parallel (up to $SYNC_JOBS at a time).
# Folder i's lines go to OUT_DIR/i.out; a failed listing leaves OUT_DIR/i.failed.
# Runs in a subshell so `wait` only sees these jobs.
list_remote_dirs() {
    local out_dir="$1"; shift
    (
        local i=0 running=0 prefix
        for prefix in "$@"; do
            if [ "$running" -ge "$SYNC_JOBS" ]; then
                wait -n; running=$((running - 1))
            fi
            { list_remote_dir "$prefix" > "$out_dir/$i.out" || : > "$out_dir/$i.failed"; } &
            running=$((running + 1)); i=$((i + 1))
        done
        wait
    )
}

# Print the manifest for the whole remote tree, listing each level of
# folders in parallel. Returns 1 if any folder couldn't be listed, since a
# missing listing would make its files look deleted remotely.
list_remote_tree() {
    local tmp level_dir f type rel _rest n=0 failed=0
    tmp=$(mktemp -d "$STATE_DIR/list.XXXXXX") || return 1
    local -a level=("") next=()
    while [ "${#level[@]}" -gt 0 ]; do
        n=$((n + 1))
        level_dir="$tmp/$n"
        mkdir "$level_dir"
        list_remote_dirs "$level_dir" "${level[@]}"
        if compgen -G "$level_dir/*.failed" >/dev/null; then
            failed=1
            break
        fi
        next=()
        for f in "$level_dir"/*.out; do
            [ -f "$f" ] || continue
            cat "$f"
            while IFS="$SEP" read -r type rel _rest; do
                [ "$type" = "folder" ] && next+=("$rel")
            done < "$f"
        done
        level=("${next[@]+"${next[@]}"}")
    done
    rm -rf -- "${tmp:?}"
    return "$failed"
}

list_remote_entry_names() {
    local json
    json=$(proton-drive filesystem list "$1" -j 2>>"$LOG_FILE") || return 1
    printf '%s' "$json" | jq -r '.[] | '"$PROTON_ENTRY_NAME_JQ"' | gsub("\n"; "\\n")'
}

trash_remote_path() {
    run_retry proton-drive filesystem trash "$1"
}

fetch_remote_fingerprint() {
    local remote_path="$1"
    local info rsize rmtime rmtime_epoch
    info=$(proton-drive filesystem info "$remote_path" -j 2>/dev/null) || true
    [ -z "$info" ] && { echo ""; return; }
    rsize=$(echo "$info" | jq -r '((.activeRevision.value // .activeRevision) | .claimedSize) // 0')
    rmtime=$(echo "$info" | jq -r '((.activeRevision.value // .activeRevision) | .claimedModificationTime) // ""')
    rmtime_epoch=0
    [ -n "$rmtime" ] && rmtime_epoch=$(date -d "$rmtime" +%s 2>/dev/null || echo 0)
    echo "${rsize}|${rmtime_epoch}"
}

# ============================================================
# DIRECTORY MANAGEMENT
# ============================================================

build_remote_dir_cache() {
    KNOWN_DIRS=()
    KNOWN_DIRS["/"]=1
    while IFS="$SEP" read -r type rel _rest; do
        [ "$type" = "folder" ] && KNOWN_DIRS["$rel"]=1
    done < "$REMOTE_MANIFEST"
}

remote_dir_exists() {
    local dir="$1"
    [ -z "$dir" ] && dir="/"
    [ -n "${KNOWN_DIRS[$dir]:-}" ]
}

create_remote_folder() {
    local parent_rel="$1"
    local folder_name="$2"
    local full_parent
    if [ -z "$parent_rel" ]; then
        full_parent="$REMOTE_DIR"
    else
        full_parent="$REMOTE_DIR/$parent_rel"
    fi
    log "[CREATE REMOTE FOLDER] $full_parent/$folder_name"
    run_retry proton-drive filesystem create-folder "$full_parent" "$folder_name"
    if [ -z "$parent_rel" ]; then
        KNOWN_DIRS["$folder_name"]=1
    else
        KNOWN_DIRS["$parent_rel/$folder_name"]=1
    fi
}

ensure_remote_folders() {
    local rel_dir="$1"
    { [ -z "$rel_dir" ] || [ "$rel_dir" = "." ]; } && return
    remote_dir_exists "$rel_dir" && return
    local current=""
    IFS='/' read -ra parts <<< "$rel_dir"
    for part in "${parts[@]}"; do
        local next
        if [ -z "$current" ]; then next="$part"; else next="$current/$part"; fi
        remote_dir_exists "$next" || create_remote_folder "$current" "$part"
        current="$next"
    done
}

ensure_local_folders() {
    local local_path="$1"
    if [ ! -d "$local_path" ]; then
        log "[CREATE LOCAL FOLDER] $local_path"
        run mkdir -p "$local_path"
    fi
}

# ============================================================
# AUTHENTICATION
# ============================================================

proton_folder_exists() {
    proton-drive filesystem list "$1" -j >/dev/null 2>&1
}

create_proton_folder() {
    proton-drive filesystem create-folder "$(dirname "$1")" "$(basename "$1")" >/dev/null
}

# Returns 0 if authenticated, 1 otherwise.
is_authenticated() {
    proton_folder_exists "$PROTON_FILES_ROOT"
}

check_remote_manifest_sane() {
    if [ ! -s "$REMOTE_MANIFEST" ] && [ -s "$SNAPSHOT" ]; then
        return 1
    fi
    return 0
}

# Interactive login flow (drops out of dialog to run the CLI login).
perform_login() {
    clear
    echo "======================================"
    echo "  Proton Drive Authentication"
    echo "======================================"
    echo
    echo "Launching 'proton-drive auth login'."
    echo "Follow the prompts below to sign in."
    echo
    proton-drive auth login
    local rc=$?
    echo
    if [ "$rc" -eq 0 ]; then
        echo "Login command completed."
    else
        echo "Login command exited with status $rc."
    fi
    read -rp "Press Enter to continue..."
    return "$rc"
}

# Ensure the user is authenticated. If not, prompt to log in,
# retrying until success or the user gives up.
# Returns 0 if authenticated, 1 if the user declined / failed.
ensure_authenticated() {
    if is_authenticated; then
        AUTH_STATE=in
        return 0
    fi
    AUTH_STATE=out

    local ans
    while true; do
        if [ -z "$UI_TOOL" ]; then
            echo "You are not logged in to Proton Drive."
            read -rp "Log in now? [Y/n] " ans
            case "$ans" in [nN]*) return 1 ;; esac
        else
            ui_yesno "Not Logged In" "You're not logged in to Proton Drive.

Log in now? (Choosing Cancel closes the app.)" "Log in" "Cancel" || return 1
        fi
        perform_login

        if is_authenticated; then
            AUTH_STATE=in
            if [ -n "$UI_TOOL" ]; then
                ui_msgbox "Logged In" "You're logged in to Proton Drive."
            else
                echo "Successfully logged in."
            fi
            return 0
        fi

        if [ -n "$UI_TOOL" ]; then
            ui_yesno "Login Failed" "Still can't open Proton Drive.

The login may not have finished. Try again?" "Try again" "Cancel" || return 1
        else
            read -rp "Login failed. Try again? [Y/n] " ans
            case "$ans" in [nN]*) return 1 ;; esac
        fi
    done
}

# ============================================================
# MOVE EXECUTION
# ============================================================

do_remote_move() {
    local old_rel="$1"
    local new_rel="$2"
    local old_parent new_parent old_base new_base target_parent_path
    old_parent=$(dirname "$old_rel"); [ "$old_parent" = "." ] && old_parent=""
    new_parent=$(dirname "$new_rel"); [ "$new_parent" = "." ] && new_parent=""
    old_base=$(basename "$old_rel")
    new_base=$(basename "$new_rel")
    if [ -z "$new_parent" ]; then
        target_parent_path="$REMOTE_DIR"
    else
        target_parent_path="$REMOTE_DIR/$new_parent"
    fi
    REMOTE_MOVE_LANDED_REL="$old_rel"
    ensure_remote_folders "$new_parent"
    if [ "$old_parent" != "$new_parent" ]; then
        run_retry proton-drive filesystem move \
            "$REMOTE_DIR/$old_rel" "$target_parent_path" || return 1
        REMOTE_MOVE_LANDED_REL="${new_parent:+$new_parent/}$old_base"
    fi
    if [ "$old_base" != "$new_base" ]; then
        run_retry proton-drive filesystem rename \
            "$target_parent_path/$old_base" "$new_base" || return 1
    fi
    REMOTE_MOVE_LANDED_REL="$new_rel"
    return 0
}
