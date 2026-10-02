#!/bin/bash

CLEANUP_DONE=0
STOP_REQUESTED=0

check_stop_requested() {
    (( STOP_REQUESTED == 0 )) || exit "$STOP_REQUESTED"
}

check_deps() {
    check_tunnel_deps
    command -v 3proxy >/dev/null 2>&1 || die "3proxy не найден"
    command -v curl   >/dev/null 2>&1 || die "curl не найден"
    command -v flock  >/dev/null 2>&1 || die "flock не найден (обычно входит в util-linux)"
    command -v getent >/dev/null 2>&1 || die "getent не найден (обычно входит в libc-bin)"
    command -v ss     >/dev/null 2>&1 || die "ss не найден (обычно входит в iproute2)"
    command -v nft    >/dev/null 2>&1 || die "nft не найден; установите nftables"
    command -v timeout >/dev/null 2>&1 || die "timeout не найден (coreutils)"
    if [[ -n "$DNS" ]]; then
        command -v resolvconf >/dev/null 2>&1 || die "DNS задан, но resolvconf не найден"
    fi
}

http_proxy_healthy() {
    proxy_health_request --proxy "http://127.0.0.1:${LOCAL_HTTP_PORT}"
}

socks_proxy_healthy() {
    proxy_health_request --socks5-hostname "127.0.0.1:${LOCAL_SOCKS_PORT}"
}

run_startup_healthcheck() {
    [[ "$STARTUP_HEALTHCHECK" != "off" ]] || return 0
    log INFO "Проверяю HTTP и SOCKS через локальные прокси..."
    local failures=0
    http_proxy_healthy || failures=$((failures + 1))
    socks_proxy_healthy || failures=$((failures + 1))
    if (( failures == 0 )); then
        log OK "HTTP и SOCKS прошли стартовую проверку"
    elif [[ "$STARTUP_HEALTHCHECK" == "strict" ]]; then
        die "HTTP/SOCKS не прошли стартовую проверку"
    else
        log WARN "HTTP/SOCKS не прошли проверку; запусти diagnose для детализации"
    fi
}

do_start() {
    log INFO "========== ЗАПУСК =========="
    load_config
    check_stop_requested
    check_deps
    [[ ! -e "$TUNNEL_OWNER_FILE" && ! -e "$GUARD_FILE" && ! -e "$PID_FILE" && ! -e "$IPV6_GUARD_FILE" ]] \
        || die "Осталось состояние предыдущего запуска; сначала выполните stop"
    block_ipv6 || die "Не удалось установить обязательную IPv6-защиту"
    check_stop_requested
    prepare_network_targets
    check_stop_requested
    ensure_proxy_ports_available
    if [[ -n "$PROXY_MAXSEG" ]]; then
        supports_proxy_maxseg || die "PROXY_MAXSEG требует 3proxy 0.9.6+"
    fi
    build_allowed_ips
    check_stop_requested
    start_tunnel
    check_stop_requested
    start_guard || die "Не удалось установить обязательную сетевую защиту"
    check_stop_requested
    start_proxy
    check_stop_requested
    run_startup_healthcheck
    check_stop_requested

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
    sandbox_stop || return 1
    stop_proxy || return 1
    stop_tunnel || return 1
    stop_guard || return 1
    unblock_ipv6 || return 1
    log OK "Всё остановлено"
}

do_stop() (
    # Serialize the whole operation, including signalling the manager: its
    # EXIT cleanup would otherwise stop the proxy before checking active run.
    sandbox_acquire_lock || die "Сначала завершите активный run"
    trap sandbox_release_lock EXIT
    do_stop_locked
)

do_stop_locked() {
    local manager_pid=""
    if is_manager_running; then
        manager_pid=$(read_pid "$MANAGER_PID_FILE")
    else
        local unverified_pid
        if unverified_pid=$(read_pid "$MANAGER_PID_FILE") && kill -0 "$unverified_pid" 2>/dev/null; then
            release_lock
            die "Живой PID менеджера не удалось идентифицировать; остановка запрещена"
        fi
    fi

    if [[ -n "$manager_pid" && "$manager_pid" != "$$" ]]; then
        log INFO "Останавливаю менеджер (PID $manager_pid)..."
        local identity
        identity=$(process_identity "$manager_pid") || { release_lock; return 1; }
        kill -TERM "$manager_pid" 2>/dev/null || { ! same_process_alive "$manager_pid" "$identity" || { release_lock; return 1; }; }
        if ! wait_for_process_exit "$manager_pid" "$identity" 600; then
            release_lock
            die "Менеджер не завершился за 60 секунд; состояние сохранено"
        fi
    fi

    acquire_lock
    if is_manager_running; then
        release_lock
        die "Во время остановки запущен новый менеджер; повторите stop"
    fi
    rm -f "$MANAGER_PID_FILE"
    stop_components || { release_lock; die "Остановка не завершена; состояние сохранено для повторного stop"; }
    release_lock
}


cleanup() {
    if [[ "$CLEANUP_DONE" == "1" ]]; then
        return
    fi
    CLEANUP_DONE=1
    if [[ "$CONFIG_LOADED" == "1" ]]; then
        log WARN "Менеджер завершает работу, останавливаю сервисы..."
        # Startup failure must not adopt resources from a previous session.
        # Keep the guard if the process cannot be confirmed stopped.
        if [[ "$PROXY_OWNED" == 0 ]] || stop_proxy; then
            if [[ "$TUNNEL_OWNED" == 0 ]] || stop_tunnel; then
                if [[ "$GUARD_OWNED" == 0 ]] || stop_guard; then
                    if [[ "$IPV6_OWNED" == 1 ]]; then
                        unblock_ipv6 || log ERR "IPv6-защита сохранена; повторите stop"
                    fi
                else
                    log ERR "Сетевая защита сохранена; повторите stop"
                fi
            else
                log ERR "Очистка туннеля не завершена; состояние и защита сохранены"
            fi
        else
            log ERR "3proxy не остановлен; сетевая защита сохранена"
        fi
    fi
    if [[ "$(read_pid "$MANAGER_PID_FILE" 2>/dev/null || true)" == "$$" ]]; then
        rm -f "$MANAGER_PID_FILE"
    fi
    release_lock
}

run_manager() {
    acquire_lock
    if is_manager_running; then
        local pid
        pid=$(read_pid "$MANAGER_PID_FILE")
        release_lock
        die "Менеджер уже запущен (PID $pid)"
    fi
    local unverified_pid
    if unverified_pid=$(read_pid "$MANAGER_PID_FILE") && kill -0 "$unverified_pid" 2>/dev/null; then
        release_lock
        die "Живой PID менеджера не удалось идентифицировать; состояние сохранено"
    fi

    rm -f "$MANAGER_PID_FILE"
    write_process_record "$MANAGER_PID_FILE" "$$"
    trap cleanup EXIT
    # Complete each resource's ownership record before acting on a signal.
    STOP_REQUESTED=0
    trap 'STOP_REQUESTED=130' INT
    trap 'STOP_REQUESTED=143' TERM

    do_start
    check_stop_requested
    trap 'exit 130' INT
    trap 'exit 143' TERM
    release_lock
    log INFO "Менеджер работает. Нажми Ctrl+C для остановки."
    while true; do
        sleep 1
    done
}
