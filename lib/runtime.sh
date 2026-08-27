#!/bin/bash

LOCK_FD=""

read_pid() {
    local file="$1" pid
    [[ -r "$file" ]] || return 1
    read -r pid < "$file"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "$pid"
}

process_cmdline_contains() {
    local pid="$1" expected="$2" cmdline
    [[ -r "/proc/${pid}/cmdline" ]] || return 1
    cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline")
    [[ "$cmdline" == *"$expected"* ]]
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || die "flock не найден (обычно входит в util-linux)"
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        die "Другая операция start/stop уже выполняется"
    fi
}

release_lock() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        exec {LOCK_FD}>&-
        LOCK_FD=""
    fi
}

is_manager_running() {
    local pid
    pid=$(read_pid "$MANAGER_PID_FILE") || return 1
    kill -0 "$pid" 2>/dev/null \
        && process_cmdline_contains "$pid" "amnezia-proxy"
}
