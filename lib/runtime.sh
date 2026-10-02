#!/bin/bash

LOCK_FD=""

run_privileged() {
    sudo -n timeout --kill-after=2 10 "$@"
}

same_process_alive() {
    local pid="$1" identity="$2" line state
    [[ -r "/proc/$pid/stat" ]] || return 1
    # The process may exit between the existence check and the read.
    line=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    state="${line##*) }"; state="${state%% *}"
    [[ "$state" != Z && "$state" != X ]] || return 1
    [[ "$(process_identity "$pid" 2>/dev/null)" == "$identity" ]]
}

wait_for_process_exit() {
    local pid="$1" identity="$2" attempts="$3" attempt
    for (( attempt=0; attempt<attempts; attempt++ )); do
        same_process_alive "$pid" "$identity" || return 0
        sleep 0.1
    done
    ! same_process_alive "$pid" "$identity"
}

process_identity() {
    local pid="$1" stat_line
    local -a fields
    [[ -r "/proc/$pid/stat" ]] || return 1
    stat_line=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    # comm may contain spaces and parentheses; the final ')' closes it.
    read -r -a fields <<< "${stat_line##*) }"
    [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s:%s' "$(cat /proc/sys/kernel/random/boot_id)" "${fields[19]}"
}

write_process_record() {
    local file="$1" pid="$2" identity
    identity=$(process_identity "$pid") || return 1
    printf '%s\n%s\n' "$pid" "$identity" > "$file"
}

process_record_matches() {
    local file="$1" pid="$2" recorded actual
    recorded=$(sed -n '2p' "$file") || return 1
    actual=$(process_identity "$pid") || return 1
    [[ -n "$recorded" && "$recorded" == "$actual" ]]
}

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
        && process_record_matches "$MANAGER_PID_FILE" "$pid" \
        && process_cmdline_contains "$pid" "amnezia-proxy"
}
