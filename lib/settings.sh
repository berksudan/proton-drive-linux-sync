# ============================================================
# DEFAULT SETTINGS
# Settings saved from the Settings menu (in $CONFIG_FILE) override these,
# and PROTON_SYNC_* environment variables override both.
# ============================================================

LOCAL_DIR=""
REMOTE_DIR=""
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
# nothing is synced.
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

CONFIG_FILE="$APP_DIR/config/settings.yaml"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/proton-drive-linux-sync"
LOCK_FILE="$STATE_ROOT/sync.lock"
RUN_LOG="$STATE_ROOT/runs.log"

# Field separator for manifests, snapshot and conflict list. The ASCII unit
# separator can't realistically appear in a filename, unlike "|".
SEP=$'\x1f'

# ============================================================
# SETTINGS FILE
# ============================================================

SETTING_KEYS=(CONFLICT_STRATEGY SYNC_JOBS
    TRASH_RETENTION_DAYS LOG_RETENTION_DAYS
    DELETE_CONFIRM_COUNT DELETE_CONFIRM_PERCENT MAX_FILE_SIZE_MB
    NOTIFY WATCH_POLL_MINUTES WATCH_DELAY_SECONDS DEBUG)
ARRAY_KEYS=(EXCLUDE_PATTERNS PAIR_LOCAL PAIR_REMOTE PAIR_MODE PAIR_SKIP)
declare -a CFG_EXCLUDE_PATTERNS=() CFG_PAIR_LOCAL=() CFG_PAIR_REMOTE=() CFG_PAIR_MODE=() CFG_PAIR_SKIP=()
ENV_PAIR=false     # true when PROTON_SYNC_LOCAL_DIR / _REMOTE_DIR set the folders

SETTINGS_YAML_TO_SHELL='
if type != "object" then error("the file must map setting names to values") else . end
| ($scalar_keys | split(" ") | map(select(length > 0))) as $scalars
| (keys - $scalars - ["exclude_patterns", "pairs"]) as $unknown
| if ($unknown | length) > 0 then error("unknown setting(s): " + ($unknown | join(", "))) else . end
| (to_entries[] | select(.key | IN($scalars[]))
    | if (.value | type | IN("string", "number", "boolean"))
      then "\(.key | ascii_upcase)=\(.value | tostring | @sh)"
      else error("setting \(.key) must be a single value") end),
  (if has("exclude_patterns") then
      if (.exclude_patterns | type) == "array" and all(.exclude_patterns[]; type == "string")
      then "EXCLUDE_PATTERNS=(\(.exclude_patterns | map(@sh) | join(" ")))"
      else error("exclude_patterns must be a list of names") end
   else empty end),
  (if has("pairs") then
      if (.pairs | type) != "array" then error("pairs must be a list") else . end
      | (.pairs | to_entries | map(
          (.key + 1) as $number | .value
          | if type != "object" then error("pair \($number) must map local, remote, mode and skip") else . end
          | (keys - ["local", "remote", "mode", "skip"]) as $extra
          | if ($extra | length) > 0 then error("pair \($number): unknown key(s): " + ($extra | join(", "))) else . end
          | if (.local | type) != "string" or (.remote | type) != "string"
            then error("pair \($number) needs a local and a remote folder") else . end
          | if (.mode // "two-way" | IN("two-way", "upload", "download")) | not
            then error("pair \($number): mode must be two-way, upload or download") else . end
          | if (.skip // [] | type) != "array" or (all((.skip // [])[]; type == "string") | not)
            then error("pair \($number): skip must be a list of folders") else . end
          | {local, remote, mode: (.mode // "two-way"), skip: ((.skip // []) | join("\n"))})) as $pairs
      | "PAIR_LOCAL=(\($pairs | map(.local | @sh) | join(" ")))",
        "PAIR_REMOTE=(\($pairs | map(.remote | @sh) | join(" ")))",
        "PAIR_MODE=(\($pairs | map(.mode | @sh) | join(" ")))",
        "PAIR_SKIP=(\($pairs | map(.skip | @sh) | join(" ")))"
   else empty end)
'

load_config() {
    local assignments i
    [ -f "$CONFIG_FILE" ] || return 0
    if ! assignments=$(yq -r --arg scalar_keys "${SETTING_KEYS[*],,}" "$SETTINGS_YAML_TO_SHELL" "$CONFIG_FILE"); then
        echo "ERROR: couldn't read the settings in $CONFIG_FILE (see the message above)." >&2
        exit 1
    fi
    eval "$assignments"
    for i in "${!PAIR_LOCAL[@]}"; do
        PAIR_LOCAL[$i]="${PAIR_LOCAL[$i]/#\~\//$HOME/}"
    done
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

pair_json() {
    jq -n --arg local "${CFG_PAIR_LOCAL[$1]}" --arg remote "${CFG_PAIR_REMOTE[$1]}" \
        --arg mode "${CFG_PAIR_MODE[$1]}" --arg skip "${CFG_PAIR_SKIP[$1]}" \
        '{local: $local, remote: $remote, mode: $mode, skip: ($skip | split("\n") | map(select(length > 0)))}'
}

save_config() {
    local tmp="$CONFIG_FILE.tmp" i settings_json
    local -a pairs_json=()
    mkdir -p "$(dirname "$CONFIG_FILE")" || return 1
    for i in "${!CFG_PAIR_LOCAL[@]}"; do
        pairs_json+=("$(pair_json "$i")") || return 1
    done
    settings_json=$(jq -n \
        --arg conflict_strategy "$CFG_CONFLICT_STRATEGY" \
        --argjson sync_jobs "$CFG_SYNC_JOBS" \
        --argjson trash_retention_days "$CFG_TRASH_RETENTION_DAYS" \
        --argjson log_retention_days "$CFG_LOG_RETENTION_DAYS" \
        --argjson delete_confirm_count "$CFG_DELETE_CONFIRM_COUNT" \
        --argjson delete_confirm_percent "$CFG_DELETE_CONFIRM_PERCENT" \
        --argjson max_file_size_mb "$CFG_MAX_FILE_SIZE_MB" \
        --arg notify "$CFG_NOTIFY" \
        --argjson watch_poll_minutes "$CFG_WATCH_POLL_MINUTES" \
        --argjson watch_delay_seconds "$CFG_WATCH_DELAY_SECONDS" \
        --argjson debug "$CFG_DEBUG" \
        --argjson exclude_patterns "$(jq -n '$ARGS.positional' --args "${CFG_EXCLUDE_PATTERNS[@]+"${CFG_EXCLUDE_PATTERNS[@]}"}")" \
        --argjson pairs "$(jq -n '$ARGS.positional' --jsonargs "${pairs_json[@]+"${pairs_json[@]}"}")" \
        '{conflict_strategy: $conflict_strategy, sync_jobs: $sync_jobs,
          trash_retention_days: $trash_retention_days, log_retention_days: $log_retention_days,
          delete_confirm_count: $delete_confirm_count, delete_confirm_percent: $delete_confirm_percent,
          max_file_size_mb: $max_file_size_mb, notify: $notify,
          watch_poll_minutes: $watch_poll_minutes, watch_delay_seconds: $watch_delay_seconds,
          debug: $debug,
          exclude_patterns: $exclude_patterns, pairs: $pairs}') || return 1
    {
        echo "# Proton Drive Linux Sync settings, written by proton-sync-tui.sh."
        echo "# Every setting is described in config/settings.example.yaml."
        yq -y . <<< "$settings_json"
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
        PAIR_LOCAL=("${PROTON_SYNC_LOCAL_DIR:-${PAIR_LOCAL[0]:-}}")
        PAIR_REMOTE=("${PROTON_SYNC_REMOTE_DIR:-${PAIR_REMOTE[0]:-}}")
        if [ -z "${PAIR_LOCAL[0]}" ] || [ -z "${PAIR_REMOTE[0]}" ]; then
            echo "ERROR: with no folder pair saved, set both PROTON_SYNC_LOCAL_DIR and PROTON_SYNC_REMOTE_DIR." >&2
            exit 2
        fi
        PAIR_MODE=("${PAIR_MODE[0]:-two-way}")
        PAIR_SKIP=("${PAIR_SKIP[0]:-}")
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
