#!/bin/bash

is_proxy_running() {
    local pid
    pid=$(read_pid "$PID_FILE") || return 1
    kill -0 "$pid" 2>/dev/null \
        && process_cmdline_contains "$pid" "3proxy" \
        && process_cmdline_contains "$pid" "$PROXY_CFG"
}

generate_proxy_config() {
    ( umask 077
      cat > "$PROXY_CFG" <<EOF
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log ${PROXY_LOG_FILE}
auth iponly
allow * 127.0.0.1

parent 1000 http ${PROXY_HOST} ${PROXY_PORT} ${PROXY_USER} ${PROXY_PASS}

proxy -p${LOCAL_HTTP_PORT} -i127.0.0.1
socks -p${LOCAL_SOCKS_PORT} -i127.0.0.1
EOF
    )
    chmod 600 "$PROXY_CFG"
}

start_proxy() {
    if is_proxy_running; then
        log WARN "3proxy уже запущен (PID $(read_pid "$PID_FILE"))"
        return 0
    fi
    rm -f "$PID_FILE"

    generate_proxy_config
    log INFO "Запускаю 3proxy..."
    3proxy "$PROXY_CFG" &
    echo $! > "$PID_FILE"
    sleep 1.2

    if is_proxy_running; then
        log OK "3proxy запущен (HTTP :${LOCAL_HTTP_PORT}, SOCKS :${LOCAL_SOCKS_PORT})"
    else
        die "Не удалось запустить 3proxy"
    fi
}

stop_proxy() {
    if is_proxy_running; then
        local pid
        pid=$(read_pid "$PID_FILE")
        kill "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
        log OK "3proxy остановлен"
    else
        rm -f "$PID_FILE"
    fi
}
