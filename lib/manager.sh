#!/bin/bash

CLEANUP_DONE=0

check_deps() {
    check_tunnel_deps
    command -v 3proxy >/dev/null 2>&1 || die "3proxy не найден"
    command -v curl   >/dev/null 2>&1 || die "curl не найден"
    command -v flock  >/dev/null 2>&1 || die "flock не найден (обычно входит в util-linux)"
}

do_start() {
    log INFO "========== ЗАПУСК =========="
    load_config
    check_deps
    build_allowed_ips
    start_tunnel
    start_proxy

    log OK "Система готова"
    echo
    if colors_enabled; then
        printf '%bИспользуй:%b\n' "$GREEN" "$NC"
    else
        echo "Используй:"
    fi
    echo "  export HTTP_PROXY=http://127.0.0.1:${LOCAL_HTTP_PORT}"
    echo "  export HTTPS_PROXY=http://127.0.0.1:${LOCAL_HTTP_PORT}"
    echo "  export ALL_PROXY=socks5h://127.0.0.1:${LOCAL_SOCKS_PORT}"
    echo
}

stop_components() {
    log INFO "========== ОСТАНОВКА =========="
    stop_proxy
    stop_tunnel
    log OK "Всё остановлено"
}

do_stop() {
    load_config
    check_tunnel_deps
    acquire_lock

    local manager_pid=""
    if is_manager_running; then
        manager_pid=$(read_pid "$MANAGER_PID_FILE")
    fi

    if [[ -n "$manager_pid" && "$manager_pid" != "$$" ]]; then
        log INFO "Останавливаю менеджер (PID $manager_pid)..."
        kill -TERM "$manager_pid" 2>/dev/null || true
        local attempt
        for (( attempt=0; attempt<50; attempt++ )); do
            kill -0 "$manager_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$manager_pid" 2>/dev/null; then
            release_lock
            die "Менеджер не завершился за 5 секунд"
        fi
    fi

    rm -f "$MANAGER_PID_FILE"
    stop_components
    release_lock
}

do_status() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Конфиг: НЕ НАЙДЕН ($CONFIG_FILE)"
        if is_manager_running; then
            echo "Менеджер: RUNNING (PID $(read_pid "$MANAGER_PID_FILE"))"
        else
            echo "Менеджер: STOPPED"
        fi
        if is_proxy_running; then
            echo "3proxy: RUNNING (PID $(read_pid "$PID_FILE"))"
        else
            echo "3proxy: STOPPED"
        fi
        return 1
    fi

    load_config
    echo "=== Статус ==="
    if is_manager_running; then
        echo "Менеджер: RUNNING (PID $(read_pid "$MANAGER_PID_FILE"))"
    else
        echo "Менеджер: STOPPED"
    fi

    if is_tunnel_up; then
        if colors_enabled; then
            printf 'Туннель (%s): %bUP%b\n' "$WG_INTERFACE" "$GREEN" "$NC"
        else
            echo "Туннель ($WG_INTERFACE): UP"
        fi
        ip -br addr show "$WG_INTERFACE" 2>/dev/null || true
        echo -n "Маршрут к $PROXY_HOST: "
        ip route get "$PROXY_HOST" 2>/dev/null | head -1 || echo "не найден"
    else
        if colors_enabled; then
            printf 'Туннель: %bDOWN%b\n' "$RED" "$NC"
        else
            echo "Туннель: DOWN"
        fi
    fi

    echo
    if is_proxy_running; then
        if colors_enabled; then
            printf '3proxy: %bRUNNING%b (PID %s)\n' "$GREEN" "$NC" "$(read_pid "$PID_FILE")"
        else
            echo "3proxy: RUNNING (PID $(read_pid "$PID_FILE"))"
        fi
        echo -n "Проверка через локальный прокси: "
        if curl -s --max-time 6 -x "http://127.0.0.1:${LOCAL_HTTP_PORT:-8081}" https://api.ipify.org; then
            echo
        elif colors_enabled; then
            printf '%bне отвечает%b\n' "$RED" "$NC"
        else
            echo "не отвечает"
        fi
    elif colors_enabled; then
        printf '3proxy: %bSTOPPED%b\n' "$RED" "$NC"
    else
        echo "3proxy: STOPPED"
    fi
}

do_test() {
    load_config
    command -v curl >/dev/null 2>&1 || die "curl не найден"
    log INFO "Тест доступности upstream-прокси..."
    if curl -s --max-time 8 -x "http://${PROXY_HOST}:${PROXY_PORT}" \
            --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
            https://api.ipify.org; then
        echo
        log OK "Upstream прокси отвечает"
    else
        die "Upstream прокси недоступен"
    fi
}

cleanup() {
    if [[ "$CLEANUP_DONE" == "1" ]]; then
        return
    fi
    CLEANUP_DONE=1
    release_lock
    if [[ "$CONFIG_LOADED" == "1" ]]; then
        log WARN "Менеджер завершает работу, останавливаю сервисы..."
        stop_components
    fi
    if [[ "$(read_pid "$MANAGER_PID_FILE" 2>/dev/null || true)" == "$$" ]]; then
        rm -f "$MANAGER_PID_FILE"
    fi
}

run_manager() {
    acquire_lock
    if is_manager_running; then
        local pid
        pid=$(read_pid "$MANAGER_PID_FILE")
        release_lock
        die "Менеджер уже запущен (PID $pid)"
    fi

    rm -f "$MANAGER_PID_FILE"
    printf '%s\n' "$$" > "$MANAGER_PID_FILE"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    do_start
    release_lock
    log INFO "Менеджер работает. Нажми Ctrl+C для остановки."
    while true; do
        sleep 1
    done
}
