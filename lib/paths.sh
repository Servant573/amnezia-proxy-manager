#!/bin/bash

APP_NAME="amnezia-proxy-manager"

CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
DEFAULT_CONFIG_FILE="${CONFIG_HOME}/${APP_NAME}/config"
LEGACY_CONFIG_FILE="${HOME}/.amnezia-proxy.conf"

USING_LEGACY_CONFIG=0
if [[ -n "${AMNEZIA_PROXY_CONFIG:-}" ]]; then
    CONFIG_FILE="$AMNEZIA_PROXY_CONFIG"
elif [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
    CONFIG_FILE="$DEFAULT_CONFIG_FILE"
elif [[ -f "$LEGACY_CONFIG_FILE" ]]; then
    CONFIG_FILE="$LEGACY_CONFIG_FILE"
    USING_LEGACY_CONFIG=1
else
    CONFIG_FILE="$DEFAULT_CONFIG_FILE"
fi

STATE_DIR="${AMNEZIA_PROXY_STATE_DIR:-${STATE_HOME}/${APP_NAME}}"
CACHE_DIR="${AMNEZIA_PROXY_CACHE_DIR:-${CACHE_HOME}/${APP_NAME}}"
if [[ -n "${AMNEZIA_PROXY_RUNTIME_DIR:-}" ]]; then
    RUNTIME_DIR="$AMNEZIA_PROXY_RUNTIME_DIR"
elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    RUNTIME_DIR="${XDG_RUNTIME_DIR}/${APP_NAME}"
else
    RUNTIME_DIR="${TMPDIR:-/tmp}/${APP_NAME}-${UID}"
fi

PROXY_CFG="${RUNTIME_DIR}/3proxy.cfg"
LOG_FILE="${STATE_DIR}/manager.log"
PROXY_LOG_FILE="${STATE_DIR}/3proxy.log"
PID_FILE="${RUNTIME_DIR}/3proxy.pid"
MANAGER_PID_FILE="${RUNTIME_DIR}/manager.pid"
LOCK_FILE="${RUNTIME_DIR}/manager.lock"
ALLOWED_IPS_CACHE="${CACHE_DIR}/allowed_ips.txt"
TUNNEL_OWNER_FILE="${RUNTIME_DIR}/tunnel.owner"
GUARD_FILE="${RUNTIME_DIR}/guard.owner"

secure_directory() {
    local path="$1" current="/" part owner mode root_owner
    root_owner=$(stat -c %u /) || return 1
    [[ "$path" == /* && "$path" != / ]] || { echo "Требуется абсолютный путь каталога: $path" >&2; return 1; }
    local -a parts
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        [[ "$part" != . && "$part" != .. ]] || return 1
        current="${current%/}/$part"
        [[ ! -L "$current" ]] || { echo "Симлинк в пути запрещён: $current" >&2; return 1; }
        if [[ ! -e "$current" ]]; then
            mkdir -m 700 -- "$current" || return 1
        fi
        [[ -d "$current" ]] || return 1
        owner=$(stat -c %u -- "$current") || return 1
        mode=$(stat -c %a -- "$current") || return 1
        [[ "$owner" == "$UID" || "$owner" == "$root_owner" ]] || { echo "Чужой владелец: $current" >&2; return 1; }
        # Shared parents such as /tmp must be root-owned and sticky.
        if (( (8#$mode & 0022) != 0 )); then
            [[ "$current" != "${path%/}" && "$owner" == "$root_owner" ]] && (( (8#$mode & 01000) != 0 )) || {
                echo "Небезопасные права каталога: $current" >&2; return 1;
            }
        fi
    done
    [[ "$(stat -c %u -- "$path")" == "$UID" ]] || return 1
    chmod 700 -- "$path" || return 1
}

init_paths() {
    local path entry
    for path in "$RUNTIME_DIR" "$STATE_DIR" "$CACHE_DIR"; do
        secure_directory "$path" || return 1
        # These directories are private; reject pre-existing links/devices and
        # hard-linked files before any redirection can overwrite their targets.
        while IFS= read -r -d '' entry; do
            [[ ! -L "$entry" && -f "$entry" && -O "$entry" ]] &&
                [[ "$(stat -c %h -- "$entry")" == 1 ]] || {
                    echo "Небезопасный файл: $entry" >&2; return 1;
                }
        done < <(find "$path" -mindepth 1 -maxdepth 1 -print0)
    done
}
