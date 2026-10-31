# ============================================================
# PROGRESS AND PLAN
# ============================================================

# gauge PERCENT MESSAGE — update the progress bar (stdout feeds the dialog;
# in headless mode it goes to /dev/null).
gauge() {
    printf 'XXX\n%s\n%s\nXXX\n' "$1" "$2"
}

# plan CATEGORY TEXT — record one action for the preview and the summary.
# Categories: up down move del_local del_remote conflict folder failed
plan() {
    printf '%s\t%s\n' "$1" "$2" >> "$PLAN_FILE"
}

plan_count() {
    grep -c "^$1"$'\t' "$PLAN_FILE" 2>/dev/null || true
}

# What happens to a conflict under the current strategy (for the preview).
conflict_note() {
    case "$CONFLICT_STRATEGY" in
        ask)    echo "you'll be asked" ;;
        local)  echo "will keep the local version" ;;
        remote) echo "will keep the Proton version" ;;
        both)   echo "will keep both" ;;
        skip)   echo "will be skipped" ;;
    esac
}

# Human-readable plan: counts, then one section per kind of change.
format_plan() {
    local -a parts=()
    local n
    n=$(plan_count up);         [ "$n" -gt 0 ] && parts+=("$n to upload")
    n=$(plan_count down);       [ "$n" -gt 0 ] && parts+=("$n to download")
    n=$(plan_count move);       [ "$n" -gt 0 ] && parts+=("$n to move")
    n=$(( $(plan_count del_local) + $(plan_count del_remote) ))
                                [ "$n" -gt 0 ] && parts+=("$n to delete")
    n=$(plan_count conflict);   [ "$n" -gt 0 ] && parts+=("$n conflicts")
    n=$(plan_count failed);     [ "$n" -gt 0 ] && parts+=("$n problems")
    if [ "${#parts[@]}" -eq 0 ]; then
        echo "No changes: everything is already in sync."
    else
        local IFS=,
        echo "${parts[*]}" | sed 's/,/, /g'
    fi
    if [ "$EMPTY_WARNING" = true ]; then
        echo
        echo "Note: the local folder is $EMPTY_LOCAL, but files were synced from it"
        echo "before. A real sync will stop and ask whether to download everything"
        echo "again (start fresh) before changing anything."
    fi
    if [ "$DELETE_WARNING" = true ]; then
        echo
        echo "Note: this is more deletions than your safety limit, so a real"
        echo "sync will ask you to confirm before deleting anything."
    fi
    awk -F'\t' '
        BEGIN {
            n = split("up down move del_local del_remote conflict folder failed note skipped", order, " ")
            title["up"] = "Upload to Proton"
            title["down"] = "Download from Proton"
            title["move"] = "Move or rename"
            title["del_local"] = "Delete locally, kept in the local trash"
            title["del_remote"] = "Delete on Proton, moved to Proton trash"
            title["conflict"] = "Conflicts, changed on both sides"
            title["folder"] = "New folders"
            title["failed"] = "Problems"
            title["note"] = "Notes"
            title["skipped"] = "Not synced"
        }
        { cat = $1; sub(/^[^\t]*\t/, ""); items[cat] = items[cat] "  " $0 "\n"; count[cat]++ }
        END {
            for (i = 1; i <= n; i++) {
                c = order[i]
                if (count[c]) printf "\n%s (%d)\n%s", title[c], count[c], items[c]
            }
        }' "$PLAN_FILE"
}

# Short one-line result, used in the status line, log list and cron log.
result_text() {
    local -a parts=()
    [ "$COUNT_UPLOADED" -gt 0 ] && parts+=("$COUNT_UPLOADED up")
    [ "$COUNT_DOWNLOADED" -gt 0 ] && parts+=("$COUNT_DOWNLOADED down")
    local moved=$((COUNT_MOVED_REMOTE + COUNT_MOVED_LOCAL))
    [ "$moved" -gt 0 ] && parts+=("$moved moved")
    local deleted=$((COUNT_DELETED_LOCAL + COUNT_TRASHED_REMOTE))
    [ "$deleted" -gt 0 ] && parts+=("$deleted deleted")
    [ "$COUNT_CONFLICTS" -gt 0 ] && parts+=("$COUNT_CONFLICTS conflicts")
    [ "${#parts[@]}" -eq 0 ] && parts+=("no changes")
    if [ "$COUNT_ERRORS" -gt 0 ]; then
        parts+=("$COUNT_ERRORS errors")
    else
        parts+=("no errors")
    fi
    local IFS=,
    echo "${parts[*]}" | sed 's/,/, /g'
}

# True if deleting N files needs the user's confirmation.
deletions_exceed_limit() {
    local n="$1" total="${#SNAPSHOT_LOCAL_FP[@]}"
    [ "$n" -eq 0 ] && return 1
    if [ "$DELETE_CONFIRM_COUNT" -gt 0 ] && [ "$n" -gt "$DELETE_CONFIRM_COUNT" ]; then
        return 0
    fi
    if [ "$DELETE_CONFIRM_PERCENT" -gt 0 ] && [ "$n" -ge 5 ] \
        && [ $((n * 100)) -gt $((DELETE_CONFIRM_PERCENT * total)) ]; then
        return 0
    fi
    return 1
}
