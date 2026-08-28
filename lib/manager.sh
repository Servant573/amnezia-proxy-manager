#!/bin/bash

CLEANUP_DONE=0

check_deps() {
    check_tunnel_deps
    command -v 3proxy >/dev/null 2>&1 || die "3proxy не найден"
    command -v curl   >/dev/null 2>&1 || die "curl не найден"
    command -v flock  >/dev/null 2>&1 || die "flock не найден (обычно входит в util-linux)"
    command -v getent >/dev/null 2>&1 || die "getent не найден (обычно входит в libc-bin)"
    command -v ss     >/dev/null 2>&1 || die "ss не найден (обычно входит в iproute2)"
}

http_proxy_healthy() {
    curl -fsS --output /dev/null --max-time 10 \
        --proxy "http://127.0.0.1:${LOCAL_HTTP_PORT}" "$HEALTHCHECK_URL"
}

socks_proxy_healthy() {
    curl -fsS --output /dev/null --max-time 10 \
        --socks5-hostname "127.0.0.1:${LOCAL_SOCKS_PORT}" "$HEALTHCHECK_URL"
}

run_startup_healthcheck() {
    [[ "$STARTUP_HEALTHCHECK" != "off" ]] || return 0
    log INFO "Проверяю полную HTTP-цепочку через локальный прокси..."
    if http_proxy_healthy; then
        log OK "HTTP-цепочка VPN → upstream-прокси работает"
    elif [[ "$STARTUP_HEALTHCHECK" == "strict" ]]; then
        die "HTTP-цепочка не прошла стартовую проверку"
    else
        log WARN "HTTP-цепочка не прошла проверку; запусти diagnose для детализации"
    fi
}

do_start() {
    log INFO "========== ЗАПУСК =========="
    load_config
    check_deps
    prepare_network_targets
    build_allowed_ips
    start_tunnel
    start_proxy
    run_startup_healthcheck

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
    local status_proxy_host
    status_proxy_host=$(proxy_configured_parent_host || true)
    status_proxy_host="${status_proxy_host:-$PROXY_HOST}"
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
        echo -n "Маршрут к upstream $status_proxy_host: "
        ip route get "$status_proxy_host" 2>/dev/null | head -1 || echo "не найден"
    else
        if colors_enabled; then
            printf 'Туннель: %bDOWN%b\n' "$RED" "$NC"
        else
            echo "Туннель: DOWN"
        fi
    fi

    echo
    if is_proxy_ready; then
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
    elif is_proxy_running; then
        if colors_enabled; then
            printf '3proxy: %bBROKEN%b — процесс существует, но не слушает оба локальных порта\n' "$RED" "$NC"
        else
            echo "3proxy: BROKEN — процесс существует, но не слушает оба локальных порта"
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

do_diagnose() {
    load_config
    check_deps
    prepare_network_targets

    local failures=0 recommended="" actual="" ip route latest now age proxy_version route_proxy
    echo "=== Диагностика VPN/proxy ==="
    echo "Конфиг: $CONFIG_FILE"
    echo "Endpoint: $ENDPOINT_HOST:$ENDPOINT_PORT (${ENDPOINT_IPS:-IPv4 не определён})"
    echo "Upstream: $PROXY_HOST:$PROXY_PORT → $PROXY_CONNECT_HOST"
    route_proxy=$(proxy_configured_parent_host || true)
    if [[ -n "$route_proxy" && "$route_proxy" != "$PROXY_CONNECT_HOST" ]]; then
        echo "Upstream DNS: активный 3proxy использует $route_proxy; для перехода на $PROXY_CONNECT_HOST нужен restart"
    fi
    route_proxy="${route_proxy:-$PROXY_CONNECT_HOST}"
    proxy_version=$(threeproxy_version || true)
    if supports_proxy_maxseg; then
        echo "3proxy version: ${proxy_version:-unknown}, TCP_MAXSEG поддерживается"
    else
        echo "3proxy version: ${proxy_version:-unknown}, TCP_MAXSEG недоступен (нужна 0.9.6+)"
    fi
    if [[ -n "$proxy_version" ]] && ! threeproxy_version_at_least 0 9 8; then
        echo "3proxy version: WARN — рекомендуется обновление до 0.9.8+ с актуальными исправлениями безопасности"
    fi

    if recommended=$(recommended_awg_mtu); then
        echo "MTU: настроено=$WG_MTU, рекомендация awg-quick=$recommended"
        if [[ "$WG_MTU" =~ ^[0-9]+$ ]] && (( WG_MTU > recommended )); then
            echo "MTU: WARN — настроенное значение выше безопасной оценки маршрута"
        fi
    else
        echo "MTU: настроено=$WG_MTU, автоматическую оценку получить не удалось"
    fi

    if is_tunnel_up; then
        actual=$(effective_tunnel_mtu || true)
        echo "Туннель: UP${actual:+, фактический MTU=$actual}"
    else
        echo "Туннель: DOWN"
        failures=$((failures + 1))
    fi

    for ip in ${ENDPOINT_IPS:-}; do
        route=$(route_for_ipv4 "$ip" || true)
        if [[ -z "$route" ]]; then
            echo "Маршрут endpoint $ip: НЕ НАЙДЕН"
            failures=$((failures + 1))
        elif route_uses_interface "$route" "$WG_INTERFACE"; then
            echo "Маршрут endpoint $ip: LOOP через $WG_INTERFACE"
            failures=$((failures + 1))
        else
            echo "Маршрут endpoint $ip: OK — $route"
        fi
    done

    route=$(route_for_ipv4 "$route_proxy" || true)
    if [[ -n "$route" ]] && route_uses_interface "$route" "$WG_INTERFACE"; then
        echo "Маршрут upstream: OK — $route"
    else
        echo "Маршрут upstream: НЕ через $WG_INTERFACE${route:+ — $route}"
        failures=$((failures + 1))
    fi

    if is_tunnel_up && latest=$(sudo -n awg show "$WG_INTERFACE" latest-handshakes 2>/dev/null); then
        latest=$(awk '$2 > max {max=$2} END {print max+0}' <<< "$latest")
        if (( latest > 0 )); then
            now=$(date +%s)
            age=$((now - latest))
            echo "Handshake: ${age} секунд назад"
        else
            echo "Handshake: ещё не зафиксирован"
            failures=$((failures + 1))
        fi
    elif is_tunnel_up; then
        echo "Handshake: недоступен без активного sudo credential"
    fi

    if is_proxy_ready; then
        echo "3proxy: RUNNING (PID $(read_pid "$PID_FILE")), оба порта слушают"
    elif is_proxy_running; then
        echo "3proxy: BROKEN — процесс существует, но listeners отсутствуют"
        failures=$((failures + 1))
    else
        echo "3proxy: STOPPED"
        failures=$((failures + 1))
    fi

    if is_proxy_ready && http_proxy_healthy; then
        echo "HTTP proxy: OK"
    else
        echo "HTTP proxy: FAIL"
        failures=$((failures + 1))
    fi
    if is_proxy_ready && socks_proxy_healthy; then
        echo "SOCKS proxy: OK"
    else
        echo "SOCKS proxy: FAIL"
        failures=$((failures + 1))
    fi

    (( failures == 0 ))
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
