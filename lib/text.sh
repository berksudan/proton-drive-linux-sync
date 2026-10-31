# ============================================================
# SHARED TEXT HELPERS
# ============================================================

ago() {
    local s=$(( $(date +%s) - $1 ))
    if ((s < 60)); then echo "just now"
    elif ((s < 3600)); then echo "$((s / 60)) min ago"
    elif ((s < 86400)); then echo "$((s / 3600)) h ago"
    else echo "$((s / 86400)) days ago"
    fi
}

# "20260927-052856" -> "2026-09-27 05:28"
pretty_stamp() {
    local s="$1"
    echo "${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}"
}

last_sync_text() {
    local when text
    if [ -s "$STATUS_FILE" ] && IFS=$'\t' read -r when text < "$STATUS_FILE"; then
        echo "$(ago "$when"): $text"
    else
        echo "never"
    fi
}

# Show paths under the home folder as ~/...
display_path() {
    if [ "$1" = "$HOME" ] || [[ "$1" == "$HOME"/* ]]; then
        echo "~${1#"$HOME"}"
    else
        echo "$1"
    fi
}

conflict_label() {
    case "$CONFLICT_STRATEGY" in
        ask)    echo "Ask me" ;;
        local)  echo "Keep local" ;;
        remote) echo "Keep Proton" ;;
        both)   echo "Keep both" ;;
        skip)   echo "Skip" ;;
    esac
}

# Text = no NUL bytes and valid UTF-8 (grep -I in a UTF-8 locale).
is_text_file() {
    [ ! -s "$1" ] || LC_ALL=C.UTF-8 grep -Iq . "$1" 2>/dev/null
}
