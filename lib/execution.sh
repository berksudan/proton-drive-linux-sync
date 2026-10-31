# ============================================================
# EXECUTION HELPERS
# ============================================================

debug() {
    if [ "$DEBUG" = true ]; then
        log "[DEBUG] $*"
    fi
}

run() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] $*"
        return 0
    fi
    "$@" >>"$LOG_FILE" 2>&1
}

retry() {
    local attempts=3
    local delay=5
    local i
    for ((i = 1; i <= attempts; i++)); do
        if "$@" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
            log "[RETRY $i/$attempts] Failed, waiting ${delay}s: $*"
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    log "[ERROR] Giving up after $attempts attempts: $*"
    return 1
}

run_retry() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] $*"
        return 0
    fi
    retry "$@"
}
