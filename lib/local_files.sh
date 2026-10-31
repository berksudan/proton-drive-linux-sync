# ============================================================
# EXCLUDE PATTERNS
# ============================================================

is_excluded() {
    local rel="$1"
    local part pattern
    local -a parts
    IFS='/' read -ra parts <<< "$rel"
    for part in "${parts[@]}"; do
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            case "$part" in
                $pattern) return 0 ;;
            esac
        done
    done
    return 1
}

# is_skipped_path REL — true if REL is (inside) a folder the pair skips.
is_skipped_path() {
    local p
    for p in "${SKIP_PATHS[@]+"${SKIP_PATHS[@]}"}"; do
        # shellcheck disable=SC2053  # $p may contain wildcards on purpose
        [[ "$1" == $p || "$1" == $p/* ]] && return 0
    done
    return 1
}

# windows_unsafe REL — true if a part of REL can't be used as a name on
# Windows (reserved characters, trailing dot or space, reserved names).
windows_unsafe() {
    local part base
    local -a parts
    IFS='/' read -ra parts <<< "$1"
    for part in "${parts[@]}"; do
        [[ "$part" == *[\<\>:\"\\\|\?\*]* ]] && return 0
        [[ "$part" == *[.\ ] ]] && return 0
        base="${part%%.*}"
        case "${base^^}" in CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]) return 0 ;; esac
    done
    return 1
}

# ============================================================
# LOCAL TRASH
# ============================================================

trash_local() {
    local local_path="$1"
    local rel="$2"
    [ -e "$local_path" ] || return 0
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] trash_local $local_path"
        return 0
    fi
    mkdir -p "$LOCAL_TRASH/$(dirname "$rel")"
    mv "$local_path" "$LOCAL_TRASH/$rel"
    log "  (recoverable in $LOCAL_TRASH/$rel)"
}

cleanup_old_trash() {
    [ "$DRY_RUN" = true ] && return 0
    [ "$TRASH_RETENTION_DAYS" -gt 0 ] || return 0
    if [ -d "$TRASH_DIR" ]; then
        find "$TRASH_DIR" -mindepth 1 -maxdepth 1 -type d \
            -mtime +"$TRASH_RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true
    fi
}

# ============================================================
# FINGERPRINTS
# ============================================================

get_local_fingerprint() {
    stat -c '%s|%Y' "$1"
}

fmt_fp() {
    local fp="$1"
    local size="${fp%%|*}"
    local mtime="${fp##*|}"
    local when="unknown"
    if [ "$mtime" != "0" ] && [ -n "$mtime" ]; then
        when=$(date -d "@$mtime" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$mtime")
    fi
    echo "${size} bytes, modified ${when}"
}
