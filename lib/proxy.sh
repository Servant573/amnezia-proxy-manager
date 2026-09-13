#!/bin/bash

PROXY_OWNED=0

is_proxy_running() {
    local pid
    pid=$(read_pid "$PID_FILE") || return 1
    kill -0 "$pid" 2>/dev/null \
        && process_record_matches "$PID_FILE" "$pid" \
        && process_cmdline_contains "$pid" "3proxy" \
        && process_cmdline_contains "$pid" "$PROXY_CFG"
}

proxy_configured_parent_host() {
    [[ -r "$PROXY_CFG" ]] || return 1
    awk '$1 == "parent" { print $4; exit }' "$PROXY_CFG"
}

threeproxy_version() {
    3proxy --version 2>&1 \
        | sed -nE 's/.*3proxy-([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' \
        | head -1
}

threeproxy_version_at_least() {
    local required_major="$1" required_minor="$2" required_patch="$3"
    local version major minor patch
    version=$(threeproxy_version)
    [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    (( major > required_major \
        || (major == required_major && minor > required_minor) \
        || (major == required_major && minor == required_minor && patch >= required_patch) ))
}

supports_proxy_maxseg() {
    threeproxy_version_at_least 0 9 6
}

is_tcp_port_listening() {
    local port="$1"
    ss -H -ltn 2>/dev/null \
        | awk -v suffix=":${port}" '$4 ~ (suffix "$") { found=1 } END { exit !found }'
}

proxy_ports_listening() {
    is_tcp_port_listening "$LOCAL_HTTP_PORT" \
        && is_tcp_port_listening "$LOCAL_SOCKS_PORT"
}

is_proxy_ready() {
    is_proxy_running && proxy_ports_listening
}

ensure_proxy_ports_available() {
    local port
    for port in "$LOCAL_HTTP_PORT" "$LOCAL_SOCKS_PORT"; do
        if is_tcp_port_listening "$port"; then
            die "Локальный TCP-порт $port уже занят"
        fi
    done
}

generate_proxy_config() {
    local parent_host="${PROXY_CONNECT_HOST:-$PROXY_HOST}"
    local socket_options=""
    if [[ -n "$PROXY_MAXSEG" ]]; then
        [[ "$PROXY_MAXSEG" =~ ^[0-9]+$ ]] || die "PROXY_MAXSEG должен быть целым числом"
        supports_proxy_maxseg \
            || die "PROXY_MAXSEG требует 3proxy 0.9.6+; установлена версия $(threeproxy_version || echo unknown)"
        socket_options=" -OcTCP_NODELAY,TCP_MAXSEG -OsTCP_NODELAY,TCP_MAXSEG"
    fi

    ( umask 077
      cat > "$PROXY_CFG" <<EOF
nscache 65536
timeouts 1 5 30 60 180 1800 15 60 15 5
log ${PROXY_LOG_FILE}
parentretries ${PROXY_PARENT_RETRIES}
EOF
      [[ -n "$PROXY_MAXSEG" ]] && echo "maxseg ${PROXY_MAXSEG}" >> "$PROXY_CFG"
      cat >> "$PROXY_CFG" <<EOF
auth iponly
allow * 127.0.0.1
parent 1000 http ${parent_host} ${PROXY_PORT} ${PROXY_USER} ${PROXY_PASS}
proxy -p${LOCAL_HTTP_PORT} -i127.0.0.1${socket_options}

flush
fakeresolve
auth iponly
allow * 127.0.0.1 * * CONNECT
parent 1000 connect+ ${parent_host} ${PROXY_PORT} ${PROXY_USER} ${PROXY_PASS}
socks -p${LOCAL_SOCKS_PORT} -i127.0.0.1${socket_options}
EOF
    )
    chmod 600 "$PROXY_CFG"
}

start_proxy() {
    if is_proxy_running; then
        die "3proxy уже запущен; сначала выполните stop"
    fi
    rm -f "$PID_FILE"

    ensure_proxy_ports_available
    generate_proxy_config
    log INFO "Запускаю 3proxy..."
    3proxy "$PROXY_CFG" &
    local proxy_pid=$!
    if ! write_process_record "$PID_FILE" "$proxy_pid"; then
        # It is our own child, not a PID recovered from disk.
        kill "$proxy_pid" 2>/dev/null || true
        wait "$proxy_pid" 2>/dev/null || true
        die "Не удалось сохранить идентификатор процесса 3proxy"
    fi
    PROXY_OWNED=1
    sleep 1.2

    if is_proxy_ready; then
        log OK "3proxy запущен (HTTP :${LOCAL_HTTP_PORT}, SOCKS :${LOCAL_SOCKS_PORT})"
    else
        stop_proxy
        die "Не удалось запустить 3proxy"
    fi
}

stop_proxy() {
    if is_proxy_running; then
        local pid attempt
        pid=$(read_pid "$PID_FILE")
        kill "$pid" 2>/dev/null || true
        for (( attempt=0; attempt<30; attempt++ )); do
            is_proxy_running || break
            sleep 0.1
        done
        if is_proxy_running; then
            log ERR "3proxy не завершился; PID и сетевая защита сохранены"
            return 1
        fi
        rm -f "$PID_FILE"
        log OK "3proxy остановлен"
    else
        local unverified_pid
        if unverified_pid=$(read_pid "$PID_FILE") && kill -0 "$unverified_pid" 2>/dev/null; then
            log ERR "PID $unverified_pid существует, но принадлежность не подтверждена; процесс не тронут"
            return 1
        fi
        rm -f "$PID_FILE"
    fi
    PROXY_OWNED=0
}
