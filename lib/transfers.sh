# ============================================================
# PARALLEL FILE TRANSFERS
# ============================================================

# queue_job KIND REL LOCAL_FP REMOTE_FP PREV_LOCAL_FP PREV_REMOTE_FP
# KIND: up_mod | down_mod | up_new | down_new | trash
queue_job() {
    JOB_QUEUE+=("$1${SEP}$2")
    JOB_LFP["$2"]="$3"; JOB_RFP["$2"]="$4"
    JOB_PREV_L["$2"]="$5"; JOB_PREV_R["$2"]="$6"
}

# Runs in a background job: do the network operation, report ok/fail.
run_one_job() {
    local kind="$1" rel="$2" rc=0
    local local_path="$LOCAL_DIR/$rel" remote_path="$REMOTE_DIR/$rel"
    case "$kind" in
        up_mod)   run_retry proton-drive filesystem upload -f replace "$local_path" "$(dirname "$remote_path")" || rc=1 ;;
        up_new)   run_retry proton-drive filesystem upload "$local_path" "$(dirname "$remote_path")" || rc=1 ;;
        down_mod) run_retry proton-drive filesystem download -f remove "$remote_path" "$(dirname "$local_path")" || rc=1 ;;
        down_new) run_retry proton-drive filesystem download "$remote_path" "$(dirname "$local_path")" || rc=1 ;;
        trash)    run_retry proton-drive filesystem trash "$remote_path" || rc=1 ;;
    esac
    local status=ok
    [ "$rc" -ne 0 ] && status=fail
    # One short line per append, so concurrent writes don't interleave.
    printf '%s\n' "${kind}${SEP}${rel}${SEP}${status}" >> "$JOB_RESULTS"
}

# Run JOB_QUEUE with up to $SYNC_JOBS jobs at a time. The pool runs in a
# subshell so `wait` only sees these jobs (not the progress dialog).
run_job_queue() {
    : > "$JOB_RESULTS"
    [ "${#JOB_QUEUE[@]}" -eq 0 ] && return 0
    (
        local spec kind rel running=0 started=0 total="${#JOB_QUEUE[@]}"
        for spec in "${JOB_QUEUE[@]}"; do
            kind="${spec%%"$SEP"*}"; rel="${spec#*"$SEP"}"
            if [ "$running" -ge "$SYNC_JOBS" ]; then
                wait -n; running=$((running - 1))
            fi
            started=$((started + 1))
            gauge $((45 + 50 * started / total)) "Transferring $started of $total: $rel"
            run_one_job "$kind" "$rel" &
            running=$((running + 1))
        done
        wait
    )
}

# Update counters and the snapshot from the job results. Uploaded files'
# new remote fingerprints are read by listing each affected folder once,
# instead of one `info` call per file.
process_job_results() {
    local kind rel status lfp
    local -a refetch=()
    [ -s "$JOB_RESULTS" ] || return 0

    while IFS="$SEP" read -r kind rel status; do
        local local_path="$LOCAL_DIR/$rel"
        if [ "$status" != ok ]; then
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            case "$kind" in
                up_*)   plan failed "Upload failed: $rel" ;;
                down_*) plan failed "Download failed: $rel" ;;
                trash)  plan failed "Deleting on Proton failed: $rel" ;;
            esac
            case "$kind" in
                up_mod|down_mod) snap_file "$rel" "${JOB_PREV_L[$rel]}" "${JOB_PREV_R[$rel]}" ;;
            esac
            continue
        fi
        case "$kind" in
            up_mod|up_new)
                COUNT_UPLOADED=$((COUNT_UPLOADED + 1))
                if [ "$DRY_RUN" = true ]; then
                    [ "$kind" = up_mod ] && snap_file "$rel" "${JOB_LFP[$rel]}" "${JOB_RFP[$rel]}"
                else
                    refetch+=("$kind${SEP}$rel")
                fi
                ;;
            down_mod)
                COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
                lfp="${JOB_LFP[$rel]}"
                [ "$DRY_RUN" = false ] && lfp=$(get_local_fingerprint "$local_path")
                snap_file "$rel" "$lfp" "${JOB_RFP[$rel]}"
                ;;
            down_new)
                if [ -f "$local_path" ]; then
                    COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
                    snap_file "$rel" "$(get_local_fingerprint "$local_path")" "${JOB_RFP[$rel]}"
                elif [ "$DRY_RUN" = false ]; then
                    COUNT_ERRORS=$((COUNT_ERRORS + 1))
                    plan failed "Download failed: $rel"
                fi
                ;;
            trash)
                COUNT_TRASHED_REMOTE=$((COUNT_TRASHED_REMOTE + 1))
                ;;
        esac
    done < "$JOB_RESULTS"
    rm -f "$JOB_RESULTS"

    [ "${#refetch[@]}" -eq 0 ] && return 0

    # List each parent folder of an uploaded file once, in parallel.
    local -A dir_seen=() remote_fp=()
    local -a dirs=()
    local spec dir tmp f type size mtime
    for spec in "${refetch[@]}"; do
        rel="${spec#*"$SEP"}"
        dir=$(dirname "$rel"); [ "$dir" = "." ] && dir=""
        if [ -z "${dir_seen[x$dir]+x}" ]; then
            dir_seen["x$dir"]=1
            dirs+=("$dir")
        fi
    done
    tmp=$(mktemp -d "$STATE_DIR/list.XXXXXX") || return 0
    list_remote_dirs "$tmp" "${dirs[@]}"
    for f in "$tmp"/*.out; do
        [ -f "$f" ] || continue
        while IFS="$SEP" read -r type rel size mtime; do
            [ "$type" = "file" ] && remote_fp["$rel"]="${size}|${mtime}"
        done < "$f"
    done
    rm -rf -- "${tmp:?}"

    for spec in "${refetch[@]}"; do
        kind="${spec%%"$SEP"*}"; rel="${spec#*"$SEP"}"
        lfp=$(get_local_fingerprint "$LOCAL_DIR/$rel")
        if [ "$kind" = up_mod ]; then
            snap_file "$rel" "$lfp" "${remote_fp[$rel]:-}"
        elif [ -n "${remote_fp[$rel]:-}" ]; then
            snap_file "$rel" "$lfp" "${remote_fp[$rel]}"
        fi
    done
}
