# ============================================================
# IN-MEMORY STATE
# ============================================================

declare -A SNAPSHOT_LOCAL_FP
declare -A SNAPSHOT_REMOTE_FP
declare -A SNAPSHOT_SEEN
declare -A LOCAL_ITEMS
declare -A REMOTE_ITEMS
declare -A KNOWN_DIRS

declare -a NEW_LOCAL_FILES=()
declare -a NEW_REMOTE_FILES=()
declare -a DELETED_REMOTELY_FILES=()
declare -a TRASH_REMOTE_FILES=()
declare -a DEL_LOCAL_FOLDERS=()
declare -a TRASH_REMOTE_FOLDERS=()

declare -A NEW_LOCAL_FP=()

# Files not synced this run: rel -> reason (Proton Doc, over the size limit)
declare -A NOT_SYNCED=()
declare -A NOT_SYNCED_CARRY=()
declare -a PROTON_DOCS=()
SYNC_MODE=two-way
declare -a SKIP_PATHS=()

# Queued file transfers (run in parallel by run_job_queue)
declare -a JOB_QUEUE=()
declare -A JOB_LFP=() JOB_RFP=() JOB_PREV_L=() JOB_PREV_R=()
ABORT_REASON=""
REMOTE_MOVE_LANDED_REL=""
declare -A NEW_REMOTE_FP=()

# Conflict queue
declare -a CONFLICTS=()
declare -A CONFLICT_LOCAL_FP=()
declare -A CONFLICT_REMOTE_FP=()
declare -A CONFLICT_PREV_L=()
declare -A CONFLICT_PREV_R=()

COUNT_OK=0
COUNT_UPLOADED=0
COUNT_DOWNLOADED=0
COUNT_MOVED_REMOTE=0
COUNT_MOVED_LOCAL=0
COUNT_DELETED_LOCAL=0
COUNT_TRASHED_REMOTE=0
COUNT_CONFLICTS=0
COUNT_ERRORS=0
COUNT_FIRST_SYNC=0


# ============================================================
# SNAPSHOT RECORDS
# ============================================================

# snap_file REL LOCAL_FP REMOTE_FP   (fingerprints are "size|mtime")
snap_file() {
    printf 'file%s%s%s%s%s%s\n' "$SEP" "$1" "$SEP" "$2" "$SEP" "$3" >> "$NEW_SNAPSHOT"
}

snap_folder() {
    printf 'folder%s%s\n' "$SEP" "$1" >> "$NEW_SNAPSHOT"
}

# ============================================================
# IN-MEMORY LOADERS
# ============================================================

load_snapshot() {
    [ -f "$SNAPSHOT" ] || return 0
    local line type rel f3 f4 f5 f6 lfp rfp
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" == *"$SEP"* ]]; then
            IFS="$SEP" read -r type rel lfp rfp <<< "$line"
        else
            # Snapshot written by an older version, separated by "|"
            IFS='|' read -r type rel f3 f4 f5 f6 <<< "$line"
            lfp="${f3}|${f4}"; rfp="${f5}|${f6}"
        fi
        SNAPSHOT_SEEN["$rel"]=1
        if [ "$type" = "file" ]; then
            SNAPSHOT_LOCAL_FP["$rel"]="$lfp"
            SNAPSHOT_REMOTE_FP["$rel"]="$rfp"
        fi
    done < "$SNAPSHOT"
}

load_manifests_to_memory() {
    local limit="larger than $MAX_FILE_SIZE_MB MB"
    while IFS="$SEP" read -r type rel _size _mtime; do
        case "$type" in
            big) NOT_SYNCED["$rel"]="$limit"; NOT_SYNCED_CARRY["$rel"]=1 ;;
            *)   LOCAL_ITEMS["${type}|${rel}"]=1 ;;
        esac
    done < "$LOCAL_MANIFEST"
    while IFS="$SEP" read -r type rel size mtime; do
        if [ "$type" = "big" ]; then
            NOT_SYNCED["$rel"]="$limit"; NOT_SYNCED_CARRY["$rel"]=1
        elif [ "$type" = "doc" ]; then
            NOT_SYNCED["$rel"]="Proton Doc, can't be downloaded"
            PROTON_DOCS+=("$rel")
        elif [ "$type" = "file" ]; then
            REMOTE_ITEMS["${type}|${rel}"]="${size}|${mtime}"
        else
            REMOTE_ITEMS["${type}|${rel}"]=""
        fi
    done < "$REMOTE_MANIFEST"
}

was_previously_synced() {
    [ -n "${SNAPSHOT_SEEN[$1]:-}" ]
}
