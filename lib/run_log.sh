# record_result TEXT — note the outcome in the log and, for real syncs,
# in the status file shown on the main menu.
record_result() {
    log "RESULT: $1"
    [ "$DRY_RUN" = true ] && return 0
    printf '%s\t%s\n' "$(date +%s)" "$1" > "$STATUS_FILE"
    append_run_log "$1"
}

run_status() {
    case "$1" in Stopped:*) echo STOPPED; return ;; esac
    if [ "$COUNT_ERRORS" -gt 0 ]; then echo ERROR
    elif [ "$COUNT_CONFLICTS" -gt 0 ]; then echo CONFLICT
    else echo OK
    fi
}

run_trigger() {
    if [ "$ACTION" = watch ]; then echo CONTINUOUS
    elif [ "$HEADLESS" = true ] && [ -t 0 ]; then echo MANUAL_HEADLESS
    elif [ "$HEADLESS" = true ]; then echo SCHEDULED_HEADLESS
    else echo MANUAL_MENU
    fi
}

append_run_log() {
    if ! { mkdir -p "$(dirname "$RUN_LOG")" && rotate_log "$RUN_LOG" \
        && printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$(run_status "$1")" "$(run_trigger)" \
            "$(pair_label "$CURRENT_PAIR")" "$1" >> "$RUN_LOG"; }; then
        log "[ERROR] Couldn't write the run log $RUN_LOG"
        notify normal "Proton Drive Linux Sync" "Couldn't write the run log $RUN_LOG"
    fi
}

show_run_log() {
    local follow="$1" lines="$2" color=false
    local -a tail_args=(-n "$lines")
    if [ ! -f "$RUN_LOG" ]; then
        echo "No runs logged yet ($RUN_LOG)."
        return 0
    fi
    [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && color=true
    [ "$follow" = true ] && tail_args+=(-f)
    tail "${tail_args[@]}" "$RUN_LOG" | awk -F '\t' -v color="$color" '
        BEGIN {
            if (color == "true") {
                dim = "\033[2m"; reset = "\033[0m"; path_color = "\033[1m"
                status_color["OK"] = "\033[32m"
                status_color["CONFLICT"] = "\033[1;33m"
                status_color["ERROR"] = "\033[1;31m"
                status_color["STOPPED"] = "\033[1;31m"
                trigger_color["CONTINUOUS"] = "\033[36m"
                trigger_color["SCHEDULED_HEADLESS"] = "\033[34m"
                trigger_color["MANUAL_HEADLESS"] = "\033[35m"
                trigger_color["MANUAL_MENU"] = "\033[35m"
            }
        }
        {
            pair = $4
            if (match($4, / (<>|->|<-) /)) {
                pair = path_color substr($4, 1, RSTART - 1) reset " " dim substr($4, RSTART + 1, RLENGTH - 2) reset \
                    " " path_color substr($4, RSTART + RLENGTH) reset
            }
            printf "%s%s%s  %s%-8s%s  %s%-18s%s  %s  %s\n", dim, $1, reset, status_color[$2], $2, reset, \
                trigger_color[$3], $3, reset, pair, $5
            fflush()
        }'
}
