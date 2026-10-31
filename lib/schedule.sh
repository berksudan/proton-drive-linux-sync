# ============================================================
# AUTOMATIC SYNC (systemd user timer / service, or cron)
# ============================================================

CRON_MARKER="# proton-drive-sync"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
TIMER_UNIT="proton-drive-sync.timer"
SERVICE_UNIT="proton-drive-sync.service"
WATCH_UNIT="proton-drive-sync-watch.service"

systemd_available() {
    command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

cron_available() {
    command -v crontab >/dev/null 2>&1
}

cron_entry() {
    cron_available || return 0
    crontab -l 2>/dev/null | grep -F "$CRON_MARKER" | head -1
}

# schedule_kind — off | hourly | six | daily | watch | custom, read from
# what is actually installed.
schedule_kind() {
    local line min hour dom mon dow cal
    if [ -f "$UNIT_DIR/$WATCH_UNIT" ]; then
        echo watch; return
    fi
    if [ -f "$UNIT_DIR/$TIMER_UNIT" ]; then
        cal=$(sed -n 's/^OnCalendar=//p' "$UNIT_DIR/$TIMER_UNIT")
        case "$cal" in
            "*-*-* *:"*)     echo hourly ;;
            "*-*-* 00/6:"*)  echo six ;;
            "*-*-* 03:"*)    echo daily ;;
            *)               echo custom ;;
        esac
        return
    fi
    line=$(cron_entry)
    if [ -z "$line" ]; then
        echo off; return
    fi
    read -r min hour dom mon dow _ <<< "$line"
    if [ "$dom $mon $dow" != "* * *" ]; then echo custom
    elif [ "$hour" = "*" ]; then echo hourly
    elif [ "$hour" = "*/6" ]; then echo six
    elif [ "$hour" = "3" ]; then echo daily
    else echo custom
    fi
}

schedule_backend() {
    if [ -f "$UNIT_DIR/$WATCH_UNIT" ] || [ -f "$UNIT_DIR/$TIMER_UNIT" ]; then
        echo systemd
    elif [ -n "$(cron_entry)" ]; then
        echo cron
    fi
}

schedule_text() {
    case "$(schedule_kind)" in
        off)    echo "off" ;;
        hourly) echo "every hour" ;;
        six)    echo "every 6 hours" ;;
        daily)  echo "daily" ;;
        watch)  echo "continuous" ;;
        custom) echo "custom schedule" ;;
    esac
}

# Quote a string for /bin/sh.
sh_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

# Quote a string for a systemd unit file.
sd_quote() {
    local v="${1//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '"%s"' "${v//%/%%}"
}

# PATH for background runs: wherever proton-drive, jq and bash live.
background_path() {
    local path_dirs="" dir tool
    for tool in proton-drive jq bash inotifywait notify-send; do
        command -v "$tool" >/dev/null 2>&1 || continue
        dir=$(dirname "$(command -v "$tool")")
        case ":$path_dirs:" in *":$dir:"*) ;; *) path_dirs="${path_dirs:+$path_dirs:}$dir" ;; esac
    done
    for dir in /usr/local/bin /usr/bin /bin; do
        case ":$path_dirs:" in *":$dir:"*) ;; *) path_dirs="${path_dirs:+$path_dirs:}$dir" ;; esac
    done
    echo "$path_dirs"
}

# Environment variables to pass on to background runs.
background_env() {
    echo "PATH=$(background_path)"
    if [ -n "${XDG_STATE_HOME:-}" ]; then
        echo "XDG_STATE_HOME=$XDG_STATE_HOME"
    fi
}

build_cron_entry() {
    local when min=$((RANDOM % 60)) cmd e
    case "$1" in
        hourly) when="$min * * * *" ;;
        six)    when="$min */6 * * *" ;;
        daily)  when="$min 3 * * *" ;;
    esac
    cmd="env"
    while IFS= read -r e; do
        cmd+=" $(sh_quote "$e")"
    done < <(background_env)
    cmd+=" $(sh_quote "$(command -v bash)") $(sh_quote "$SCRIPT_PATH") --headless"
    cmd+=" >> $(sh_quote "$STATE_ROOT/cron.log") 2>&1"
    # cron treats a bare % as a line break.
    echo "$when ${cmd//%/\\%} $CRON_MARKER"
}

# install_cron_entry LINE — replace this script's crontab line ("" removes it).
install_cron_entry() {
    local line="$1"
    {
        crontab -l 2>/dev/null | grep -vF "$CRON_MARKER"
        [ -n "$line" ] && printf '%s\n' "$line"
    } | crontab -
}

write_systemd_units() {
    local kind="$1" env_lines="" e min=$((RANDOM % 60)) cal
    while IFS= read -r e; do
        env_lines+="Environment=$(sd_quote "$e")"$'\n'
    done < <(background_env)
    mkdir -p "$UNIT_DIR" || return 1
    if [ "$kind" = watch ]; then
        cat > "$UNIT_DIR/$WATCH_UNIT" <<UNIT
[Unit]
Description=Proton Drive Sync (continuous)
After=network-online.target

[Service]
Type=simple
${env_lines}ExecStart=$(command -v bash) $(sd_quote "$SCRIPT_PATH") --watch
Restart=on-failure
RestartSec=60

[Install]
WantedBy=default.target
UNIT
        return
    fi
    case "$kind" in
        hourly) cal="*-*-* *:$(printf %02d "$min"):00" ;;
        six)    cal="*-*-* 00/6:$(printf %02d "$min"):00" ;;
        daily)  cal="*-*-* 03:$(printf %02d "$min"):00" ;;
    esac
    cat > "$UNIT_DIR/$SERVICE_UNIT" <<UNIT
[Unit]
Description=Proton Drive Sync
After=network-online.target

[Service]
Type=oneshot
${env_lines}ExecStart=$(command -v bash) $(sd_quote "$SCRIPT_PATH") --headless
UNIT
    cat > "$UNIT_DIR/$TIMER_UNIT" <<UNIT
[Unit]
Description=Proton Drive Sync schedule

[Timer]
OnCalendar=$cal
# Catch up on a missed sync after the computer was asleep or off.
Persistent=true

[Install]
WantedBy=timers.target
UNIT
}

remove_automatic_sync() {
    if [ -f "$UNIT_DIR/$TIMER_UNIT" ] || [ -f "$UNIT_DIR/$WATCH_UNIT" ]; then
        systemctl --user disable --now "$TIMER_UNIT" >/dev/null 2>&1
        systemctl --user disable --now "$WATCH_UNIT" >/dev/null 2>&1
        rm -f "$UNIT_DIR/$TIMER_UNIT" "$UNIT_DIR/$SERVICE_UNIT" "$UNIT_DIR/$WATCH_UNIT"
        systemctl --user daemon-reload >/dev/null 2>&1
    fi
    if [ -n "$(cron_entry)" ]; then
        install_cron_entry ""
    fi
    return 0
}

# apply_automatic_sync KIND — install automatic sync (off removes it).
# Uses a systemd user timer when available (it catches up after sleep),
# otherwise cron. Continuous sync needs systemd. Prints the backend used.
apply_automatic_sync() {
    local kind="$1"
    remove_automatic_sync
    [ "$kind" = off ] && return 0
    if systemd_available; then
        write_systemd_units "$kind" || return 1
        systemctl --user daemon-reload >/dev/null 2>&1
        if [ "$kind" = watch ]; then
            systemctl --user enable --now "$WATCH_UNIT" >/dev/null 2>&1 || return 1
        else
            systemctl --user enable --now "$TIMER_UNIT" >/dev/null 2>&1 || return 1
        fi
        echo systemd
    elif [ "$kind" != watch ] && cron_available; then
        install_cron_entry "$(build_cron_entry "$kind")" || return 1
        echo cron
    else
        return 1
    fi
}

schedule_from_cli() {
    local kind="$1" used
    if [ "$kind" = watch ] && ! command -v inotifywait >/dev/null 2>&1; then
        echo "ERROR: continuous sync needs inotifywait (for example: sudo apt install inotify-tools)" >&2
        return 1
    fi
    if ! used=$(apply_automatic_sync "$kind"); then
        echo "ERROR: couldn't set up automatic sync. Check that systemd or cron is working for your user." >&2
        return 1
    fi
    echo "Automatic sync: $(schedule_text)${used:+ (using $used)}"
}
