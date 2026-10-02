#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

colors_enabled() {
    [[ -t 1 && -z "${NO_COLOR:-}" ]]
}

log() {
    local level="$1"
    shift
    local msg="$*" ts color="" padding=""
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO) color="$BLUE"; padding="  " ;;
        OK)   color="$GREEN"; padding="    " ;;
        WARN) color="$YELLOW"; padding="  " ;;
        ERR)  color="$RED"; padding="   " ;;
    esac

    if [[ "${LOG_TO_FILE:-1}" == 1 ]]; then
        printf '%s [%s]%s%s\n' "$ts" "$level" "$padding" "$msg" >> "$LOG_FILE"
    fi
    if colors_enabled && [[ -n "$color" ]]; then
        printf '%s %b[%s]%b%s%s\n' "$ts" "$color" "$level" "$NC" "$padding" "$msg"
    else
        printf '%s [%s]%s%s\n' "$ts" "$level" "$padding" "$msg"
    fi
}

die() {
    log ERR "$*"
    exit 1
}

prepare_log_for_follow() {
    local path="$1"
    [[ ! -L "$path" ]] || return 1
    if [[ ! -e "$path" ]]; then
        # Do not overwrite an entry that appeared after the existence check.
        ( umask 077; set -o noclobber; : > "$path" ) 2>/dev/null \
            || [[ -f "$path" && ! -L "$path" ]] || return 1
    fi
    [[ ! -L "$path" && -f "$path" && -O "$path" ]] || return 1
    [[ "$(stat -c %h -- "$path")" == 1 ]] || return 1
    chmod 600 -- "$path"
}

do_logs() {
    command -v tail >/dev/null 2>&1 || die "tail не найден (обычно входит в coreutils)"
    prepare_log_for_follow "$LOG_FILE" || die "Небезопасный файл лога: $LOG_FILE"
    prepare_log_for_follow "$PROXY_LOG_FILE" || die "Небезопасный файл лога: $PROXY_LOG_FILE"
    prepare_log_for_follow "$SANDBOX_LOG_FILE" || die "Небезопасный файл лога: $SANDBOX_LOG_FILE"
    printf 'Логи менеджера, 3proxy и sandbox (Ctrl+C для выхода):\n  %s\n  %s\n  %s\n' \
        "$LOG_FILE" "$PROXY_LOG_FILE" "$SANDBOX_LOG_FILE"
    tail -n 100 -F -- "$LOG_FILE" "$PROXY_LOG_FILE" "$SANDBOX_LOG_FILE"
}
