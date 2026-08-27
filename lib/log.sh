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

    printf '%s [%s]%s%s\n' "$ts" "$level" "$padding" "$msg" >> "$LOG_FILE"
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
