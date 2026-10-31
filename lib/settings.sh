# ============================================================
# DEFAULT SETTINGS
# Settings saved from the Settings menu (in $CONFIG_FILE) override these,
# and PROTON_SYNC_* environment variables override both.
# ============================================================

LOCAL_DIR="$HOME/Proton Drive/root"
REMOTE_DIR="/my-files"
CONFLICT_STRATEGY=ask          # ask | local | remote | both | skip
SYNC_JOBS=4                    # transfers / folder listings at the same time
TRASH_RETENTION_DAYS=30
LOG_RETENTION_DAYS=90
DELETE_CONFIRM_COUNT=50        # confirm before deleting more files than this (0 = off)
DELETE_CONFIRM_PERCENT=25      # ...or more than this % of synced files (0 = off)
MAX_FILE_SIZE_MB=0             # skip files larger than this (0 = no limit)
NOTIFY=off                     # background sync notifications: off | problems | changes
WATCH_POLL_MINUTES=15          # continuous sync: how often to check Proton for changes
WATCH_DELAY_SECONDS=5          # continuous sync: wait this long after the last local change
DEBUG=false

# Folder pairs, edited from the Folder pairs menu. With no saved pairs,
# LOCAL_DIR and REMOTE_DIR above become the first one.
#   PAIR_MODE: two-way | upload (backup to Proton) | download (from Proton)
#   PAIR_SKIP: folders or files (relative paths, one per line) not to sync
PAIR_LOCAL=()
PAIR_REMOTE=()
PAIR_MODE=()
PAIR_SKIP=()
CURRENT_PAIR=0

EXCLUDE_PATTERNS=(
    "*.tmp"
    "*.swp"
    "*.partial"
    ".DS_Store"
    "Thumbs.db"
    ".git"
    ".proton-sync"
)

# ============================================================
# FILE LOCATIONS
# ============================================================

CONFIG_FILE="${PROTON_SYNC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/proton-sync/config}"
STATE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/proton-sync"
LOCK_FILE="$STATE_ROOT/sync.lock"
RUN_LOG="$STATE_ROOT/run-logs/runs.log"

# Field separator for manifests, snapshot and conflict list. The ASCII unit
# separator can't realistically appear in a filename, unlike "|".
SEP=$'\x1f'

# ============================================================
# SETTINGS FILE
# ============================================================

SETTING_KEYS=(CONFLICT_STRATEGY SYNC_JOBS
    TRASH_RETENTION_DAYS LOG_RETENTION_DAYS
    DELETE_CONFIRM_COUNT DELETE_CONFIRM_PERCENT MAX_FILE_SIZE_MB
    NOTIFY WATCH_POLL_MINUTES WATCH_DELAY_SECONDS CURRENT_PAIR DEBUG)
ARRAY_KEYS=(EXCLUDE_PATTERNS PAIR_LOCAL PAIR_REMOTE PAIR_MODE PAIR_SKIP)
declare -a CFG_EXCLUDE_PATTERNS=() CFG_PAIR_LOCAL=() CFG_PAIR_REMOTE=() CFG_PAIR_MODE=() CFG_PAIR_SKIP=()
ENV_PAIR=false     # true when PROTON_SYNC_LOCAL_DIR / _REMOTE_DIR set the folders

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        if ! source "$CONFIG_FILE"; then
            echo "WARNING: could not read settings from $CONFIG_FILE" >&2
        fi
    fi
    # Settings from before folder pairs had a single LOCAL_DIR / REMOTE_DIR.
    if [ "${#PAIR_LOCAL[@]}" -eq 0 ]; then
        PAIR_LOCAL=("$LOCAL_DIR")
        PAIR_REMOTE=("$REMOTE_DIR")
        PAIR_MODE=(two-way)
        PAIR_SKIP=("")
    fi
}

# copy_array SOURCE_NAME DEST_NAME
copy_array() {
    local -n _src="$1" _dst="$2"
    _dst=("${_src[@]+"${_src[@]}"}")
}

# Keep a copy of the saved (not environment-overridden) values, so saving
# from the menus never writes a temporary override to the file.
remember_saved_settings() {
    local key
    for key in "${SETTING_KEYS[@]}"; do
        printf -v "CFG_$key" '%s' "${!key}"
    done
    for key in "${ARRAY_KEYS[@]}"; do
        copy_array "$key" "CFG_$key"
    done
}

save_config() {
    local key var tmp="$CONFIG_FILE.tmp"
    mkdir -p "$(dirname "$CONFIG_FILE")" || return 1
    {
        echo "# Proton Drive Sync settings, written by proton-sync-tui.sh."
        echo "# Edit with the menus, or by hand (this file is bash)."
        for key in "${SETTING_KEYS[@]}"; do
            var="CFG_$key"
            printf '%s=%q\n' "$key" "${!var}"
        done
        for key in "${ARRAY_KEYS[@]}"; do
            local -n _arr="CFG_$key"
            printf '%s=(' "$key"
            [ "${#_arr[@]}" -gt 0 ] && printf ' %q' "${_arr[@]}"
            printf ' )\n'
            unset -n _arr
        done
    } > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

# set_setting KEY VALUE — change a setting now and save it.
set_setting() {
    printf -v "$1" '%s' "$2"
    printf -v "CFG_$1" '%s' "$2"
    save_config
}

# set_pair_field PAIR_ARRAY INDEX VALUE — change one folder pair and save it.
set_pair_field() {
    local -n _live="$1" _saved="CFG_$1"
    _live[$2]="$3"
    _saved[$2]="$3"
    save_config
}

apply_env_overrides() {
    if [ -n "${PROTON_SYNC_LOCAL_DIR:-}${PROTON_SYNC_REMOTE_DIR:-}" ]; then
        # Folders given in the environment replace the pair list for this run.
        ENV_PAIR=true
        local i="$CURRENT_PAIR"
        is_number "$i" && [ "$i" -lt "${#PAIR_LOCAL[@]}" ] || i=0
        PAIR_LOCAL=("${PROTON_SYNC_LOCAL_DIR:-${PAIR_LOCAL[$i]}}")
        PAIR_REMOTE=("${PROTON_SYNC_REMOTE_DIR:-${PAIR_REMOTE[$i]}}")
        PAIR_MODE=("${PAIR_MODE[$i]:-two-way}")
        PAIR_SKIP=("${PAIR_SKIP[$i]:-}")
        CURRENT_PAIR=0
    fi
    CONFLICT_STRATEGY="${PROTON_SYNC_CONFLICT:-$CONFLICT_STRATEGY}"
    SYNC_JOBS="${PROTON_SYNC_JOBS:-$SYNC_JOBS}"
    DEBUG="${PROTON_SYNC_DEBUG:-$DEBUG}"
}

is_number() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

strip_slash() {
    if [ "$1" = "/" ]; then echo "/"; else echo "${1%/}"; fi
}

validate_settings() {
    is_number "$SYNC_JOBS" && [ "$SYNC_JOBS" -gt 0 ] || SYNC_JOBS=4
    is_number "$TRASH_RETENTION_DAYS" || TRASH_RETENTION_DAYS=30
    is_number "$LOG_RETENTION_DAYS" || LOG_RETENTION_DAYS=90
    is_number "$DELETE_CONFIRM_COUNT" || DELETE_CONFIRM_COUNT=50
    is_number "$DELETE_CONFIRM_PERCENT" || DELETE_CONFIRM_PERCENT=25
    is_number "$MAX_FILE_SIZE_MB" || MAX_FILE_SIZE_MB=0
    is_number "$WATCH_POLL_MINUTES" && [ "$WATCH_POLL_MINUTES" -gt 0 ] || WATCH_POLL_MINUTES=15
    is_number "$WATCH_DELAY_SECONDS" && [ "$WATCH_DELAY_SECONDS" -gt 0 ] || WATCH_DELAY_SECONDS=5
    case "$CONFLICT_STRATEGY" in ask|local|remote|both|skip) ;; *) CONFLICT_STRATEGY=ask ;; esac
    case "$NOTIFY" in off|problems|changes) ;; *) NOTIFY=off ;; esac
    [ "$DEBUG" = true ] || DEBUG=false

    local i
    for i in "${!PAIR_LOCAL[@]}"; do
        PAIR_LOCAL[$i]=$(strip_slash "${PAIR_LOCAL[$i]}")
        PAIR_REMOTE[$i]=$(strip_slash "${PAIR_REMOTE[$i]:-/my-files}")
        case "${PAIR_MODE[$i]:-}" in two-way|upload|download) ;; *) PAIR_MODE[$i]=two-way ;; esac
        PAIR_SKIP[$i]="${PAIR_SKIP[$i]:-}"
    done
    is_number "$CURRENT_PAIR" && [ "$CURRENT_PAIR" -lt "${#PAIR_LOCAL[@]}" ] || CURRENT_PAIR=0
}

# select_pair INDEX — make a folder pair the one the engine and menus use.
select_pair() {
    CURRENT_PAIR="$1"
    LOCAL_DIR="${PAIR_LOCAL[$1]}"
    REMOTE_DIR="${PAIR_REMOTE[$1]}"
    SYNC_MODE="${PAIR_MODE[$1]}"
    SKIP_PATHS=()
    local line
    while IFS= read -r line; do
        line="${line#/}"; line="${line%/}"
        [ -n "$line" ] && SKIP_PATHS+=("$line")
    done <<< "${PAIR_SKIP[$1]}"
    init_state_paths
}

pair_count() {
    echo "${#PAIR_LOCAL[@]}"
}

mode_label() {
    case "$1" in
        two-way)  echo "two-way" ;;
        upload)   echo "backup to Proton (upload only)" ;;
        download) echo "download from Proton only" ;;
    esac
}
