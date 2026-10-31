# ============================================================
# USER INTERFACE LAYER (dialog, or whiptail as a fallback)
# ============================================================

UI_TOOL=""
UI_BACKTITLE="Proton Drive Linux Sync"
AUTH_STATE=unknown     # in | out | unknown

# Use $PROTON_SYNC_UI if set, else dialog, else whiptail.
find_ui_tool() {
    local tool
    for tool in ${PROTON_SYNC_UI:-} dialog whiptail; do
        if command -v "$tool" >/dev/null 2>&1; then
            UI_TOOL="$tool"
            return 0
        fi
    done
    return 1
}

# Fit dialogs to the terminal (checked every time, so resizing works).
ui_size() {
    local rows=24 cols=80 size
    if size=$(stty size < /dev/tty 2>/dev/null) && [ -n "$size" ]; then
        rows="${size% *}"; cols="${size#* }"
    fi
    UI_H=$((rows - 4)); ((UI_H > 30)) && UI_H=30; ((UI_H < 10)) && UI_H=10
    UI_W=$((cols - 6)); ((UI_W > 100)) && UI_W=100; ((UI_W < 40)) && UI_W=40
}

# ui_fit TEXT EXTRA_ROWS — size a box for TEXT (sets BOX_H and BOX_W).
ui_fit() {
    local text="$1" extra="$2" line longest=0 rows=0 inner
    ui_size
    while IFS= read -r line; do
        ((${#line} > longest)) && longest=${#line}
    done <<< "$text"
    BOX_W=$((longest + 6)); ((BOX_W < 50)) && BOX_W=50; ((BOX_W > UI_W)) && BOX_W=$UI_W
    inner=$((BOX_W - 4))
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            rows=$((rows + 1))
        elif ((${#line} <= inner)); then
            rows=$((rows + 1))
        else
            # Wrapping happens at spaces, which can take an extra row.
            rows=$((rows + (${#line} + inner - 1) / inner + 1))
        fi
    done <<< "$text"
    BOX_H=$((rows + extra)); ((BOX_H > UI_H)) && BOX_H=$UI_H
}

_ui() {
    local -a common=(--backtitle "$UI_BACKTITLE")
    [ "$UI_TOOL" = dialog ] && common+=(--no-collapse)
    "$UI_TOOL" "${common[@]}" "$@"
}

ui_msgbox() {   # TITLE TEXT
    ui_fit "$2" 6
    _ui --title "$1" --msgbox "$2" "$BOX_H" "$BOX_W"
}

ui_infobox() {  # TITLE TEXT
    ui_fit "$2" 4
    _ui --title "$1" --infobox "$2" "$BOX_H" "$BOX_W"
}

ui_yesno() {    # TITLE TEXT [YES_LABEL NO_LABEL] — returns 0 for yes
    local -a labels=()
    if [ -n "${3:-}" ]; then
        if [ "$UI_TOOL" = dialog ]; then
            labels=(--yes-label "$3" --no-label "${4:-No}")
        else
            labels=(--yes-button "$3" --no-button "${4:-No}")
        fi
    fi
    ui_fit "$2" 6
    _ui --title "$1" "${labels[@]}" --yesno "$2" "$BOX_H" "$BOX_W"
}

ui_input() {    # TITLE TEXT DEFAULT — prints the entered value
    ui_fit "$2" 8
    _ui --title "$1" --inputbox "$2" "$BOX_H" "$BOX_W" "$3" 3>&1 1>&2 2>&3
}

ui_textbox() {  # TITLE FILE
    ui_size
    if [ "$UI_TOOL" = dialog ]; then
        _ui --title "$1" --exit-label "Close" --textbox "$2" "$UI_H" "$UI_W"
    else
        _ui --title "$1" --scrolltext --textbox "$2" "$UI_H" "$UI_W"
    fi
}

ui_gauge() {    # TITLE — reads the gauge protocol from stdin
    ui_size
    _ui --title "$1" --gauge "Starting..." 8 "$UI_W" 0
}

# Size a list box: TEXT, number of items, longest item (sets BOX_H/BOX_W/LIST_H).
_ui_list_size() {
    local text="$1" n="$2" longest="$3" text_h max_list
    ui_fit "$text" 0
    text_h=$BOX_H
    max_list=$((UI_H - text_h - 7)); ((max_list < 3)) && max_list=3
    LIST_H=$n; ((LIST_H > max_list)) && LIST_H=$max_list; ((LIST_H < 1)) && LIST_H=1
    BOX_H=$((text_h + LIST_H + 7)); ((BOX_H > UI_H)) && BOX_H=$UI_H
    ((longest + 12 > BOX_W)) && BOX_W=$((longest + 12))
    ((BOX_W > UI_W)) && BOX_W=$UI_W
}

# ui_menu TITLE TEXT CANCEL_LABEL DEFAULT_TAG TAG ITEM... — prints the chosen
# tag. Tags are hidden; an empty CANCEL_LABEL hides the cancel button.
ui_menu() {
    local title="$1" text="$2" cancel="$3" default="$4"; shift 4
    local -a opts=()
    local i longest=0
    local item
    for ((i = 2; i <= $#; i += 2)); do
        item="${!i}"
        ((${#item} > longest)) && longest=${#item}
    done
    _ui_list_size "$text" $(($# / 2)) "$longest"
    [ -n "$default" ] && opts+=(--default-item "$default")
    if [ "$UI_TOOL" = dialog ]; then
        opts+=(--no-tags)
        if [ -z "$cancel" ]; then opts+=(--no-cancel); else opts+=(--cancel-label "$cancel"); fi
    else
        opts+=(--notags)
        if [ -z "$cancel" ]; then opts+=(--nocancel); else opts+=(--cancel-button "$cancel"); fi
    fi
    _ui --title "$title" "${opts[@]}" --menu "$text" "$BOX_H" "$BOX_W" "$LIST_H" "$@" 3>&1 1>&2 2>&3
}

# ui_checklist TITLE TEXT TAG ITEM STATUS... — prints chosen tags, one per line.
ui_checklist() {
    local title="$1" text="$2"; shift 2
    local i longest=0
    local item
    for ((i = 2; i <= $#; i += 3)); do
        item="${!i}"
        ((${#item} > longest)) && longest=${#item}
    done
    _ui_list_size "$text" $(($# / 3)) $((longest + 4))
    local notags=--no-tags
    [ "$UI_TOOL" = whiptail ] && notags=--notags
    _ui --title "$title" --separate-output "$notags" \
        --checklist "$text" "$BOX_H" "$BOX_W" "$LIST_H" "$@" 3>&1 1>&2 2>&3
}
