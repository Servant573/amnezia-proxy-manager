#!/bin/bash

# Commands return 0 verified, 1 unhealthy, 2 incomplete/invalid, 3 stopped.
do_status() { diagnose_runtime status; }
do_diagnose() { diagnose_runtime diagnose; }

do_test() {
    load_config
    command -v curl >/dev/null || die "curl не найден"
    local host
    host=$(proxy_configured_parent_host || true)
    if ! is_proxy_running || ! is_ipv4 "$host"; then
        host=$(resolve_ipv4_host "$PROXY_HOST") || die "Не удалось разрешить upstream"
        host="${host%% *}"
    fi
    log INFO "Проверка доступности upstream (сама по себе не подтверждает VPN)..."
    if proxy_health_request --proxy "http://$host:$PROXY_PORT" --proxy-user "$PROXY_USER:$PROXY_PASS"; then
        log OK "Upstream вернул успешный HTTP-ответ"
    else
        die "Upstream не прошёл проверку"
    fi
}

diagnose_runtime() {
    local mode="$1" failures=0 unknown=0 config_result owner_iface owner_index owner_boot
    local route actual_endpoint latest now age endpoint_output owned=0 proxy_ready=0 guard_status
    local actual recommended field value active_http active_socks active_parent active_port
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Конфиг: НЕ НАЙДЕН ($CONFIG_FILE)"
        return 2
    fi
    if ! config_result=$( (LOG_TO_FILE=0; load_config) 2>&1); then
        printf '%s\n' "$config_result"
        return 2
    fi
    load_config >/dev/null
    echo '=== Состояние VPN/proxy ==='
    if ! is_manager_running && ! is_proxy_running && ! is_tunnel_up &&
        [[ ! -e "$MANAGER_PID_FILE" && ! -e "$PID_FILE" && ! -e "$TUNNEL_OWNER_FILE" && ! -e "$GUARD_FILE" ]]; then
        echo 'Менеджер: STOPPED; туннель: DOWN; 3proxy: STOPPED'
        return 3
    fi
    if is_manager_running; then echo 'Менеджер: RUNNING'; else echo 'Менеджер: STOPPED/UNKNOWN'; failures=$((failures + 1)); fi

    # Use the active snapshot; edits to the user's config take effect on restart.
    if [[ -r "$TUNNEL_OWNER_FILE" ]] && read -r owner_iface owner_index owner_boot < "$TUNNEL_OWNER_FILE" &&
        [[ "$owner_iface" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ && "$owner_iface" != . && "$owner_iface" != .. && "$owner_index" =~ ^[1-9][0-9]*$ ]]; then
        [[ "$WG_INTERFACE" == "$owner_iface" ]] || echo "Конфиг изменён: проверяю активный интерфейс $owner_iface"
        WG_INTERFACE="$owner_iface"
        WG_TMP_CONF="$RUNTIME_DIR/$owner_iface.conf"
        if [[ "$owner_boot" == "$(cat /proc/sys/kernel/random/boot_id)" ]] &&
            [[ "$(interface_index "$WG_INTERFACE" 2>/dev/null || true)" == "$owner_index" ]]; then
            owned=1
        fi
    fi
    if (( owned )); then
        echo "Туннель: UP, принадлежность подтверждена ($WG_INTERFACE)"
    else
        echo 'Туннель: DOWN или принадлежность не подтверждена'
        failures=$((failures + 1))
    fi
    # Only read non-secret fields; do not source generated configuration.
    if [[ -r "$WG_TMP_CONF" ]]; then
        while IFS='=' read -r field value; do
            field=$(trim "$field"); value=$(trim "$value")
            case "$field" in PublicKey) PUBLIC_KEY="$value" ;; esac
        done < "$WG_TMP_CONF"
    fi
    active_http=$(awk '$1 == "proxy" {for(i=2;i<=NF;i++) if ($i ~ /^-p[0-9]+$/) {print substr($i,3); exit}}' "$PROXY_CFG" 2>/dev/null || true)
    active_socks=$(awk '$1 == "socks" {for(i=2;i<=NF;i++) if ($i ~ /^-p[0-9]+$/) {print substr($i,3); exit}}' "$PROXY_CFG" 2>/dev/null || true)
    active_parent=$(proxy_configured_parent_host || true)
    active_port=$(awk '$1 == "parent" {print $5; exit}' "$PROXY_CFG" 2>/dev/null || true)
    if is_uint_between "$active_http" 1 65535 && is_uint_between "$active_socks" 1 65535 &&
        is_ipv4 "$active_parent" && is_uint_between "$active_port" 1 65535; then
        LOCAL_HTTP_PORT="$active_http"; LOCAL_SOCKS_PORT="$active_socks"
        PROXY_CONNECT_HOST="$active_parent"; PROXY_PORT="$active_port"
        echo "Активный upstream: $PROXY_CONNECT_HOST:$PROXY_PORT"
    else
        echo 'Активная конфигурация 3proxy: отсутствует/повреждена'
        failures=$((failures + 1))
        PROXY_CONNECT_HOST=""
    fi
    if is_proxy_ready; then
        echo '3proxy: RUNNING, оба loopback-listener принадлежат процессу'
        proxy_ready=1
    else
        echo '3proxy: STOPPED/BROKEN — PID или принадлежность listeners не подтверждены'
        failures=$((failures + 1))
    fi
    route=$(route_for_ipv4 "$PROXY_CONNECT_HOST" || true)
    if (( owned )) && [[ -n "$route" ]] && route_uses_interface "$route" "$WG_INTERFACE"; then
        echo "Маршрут upstream: OK — $route"
    else
        echo 'Маршрут upstream: FAIL'
        failures=$((failures + 1))
    fi
    if guard_is_active; then
        echo 'Firewall: OK — правило проверено'
    else
        guard_status=$?
        if (( guard_status == 2 )); then
            echo 'Firewall: UNKNOWN — проверьте nft, python3 и sudo -v'
            unknown=$((unknown + 1))
        else
            echo 'Firewall: FAIL — правило отсутствует, изменено или относится к другому интерфейсу'
            failures=$((failures + 1))
        fi
    fi

    # Inspect the peer's actual endpoint, not a fresh DNS answer.
    if (( owned )) && endpoint_output=$(run_privileged awg show "$WG_INTERFACE" endpoints 2>/dev/null); then
        actual_endpoint=$(awk -v key="$PUBLIC_KEY" '$1 == key {print $2; exit}' <<< "$endpoint_output")
        if [[ "$actual_endpoint" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
            ENDPOINT_HOST="${BASH_REMATCH[1]}"; ENDPOINT_PORT="${BASH_REMATCH[2]}"
            route=$(ip -6 route get "$ENDPOINT_HOST" 2>/dev/null || true)
            ENDPOINT_IPS=""
        elif [[ "$actual_endpoint" =~ ^([0-9.]+):([0-9]+)$ ]]; then
            ENDPOINT_HOST="${BASH_REMATCH[1]}"; ENDPOINT_PORT="${BASH_REMATCH[2]}"
            ENDPOINT_IPS="$ENDPOINT_HOST"
            route=$(route_for_ipv4 "$ENDPOINT_HOST" || true)
        else
            route=""
        fi
        if [[ -n "$route" ]] && ! route_uses_interface "$route" "$WG_INTERFACE"; then
            echo "Endpoint: OK — $actual_endpoint, $route"
        else
            echo 'Endpoint: FAIL — отсутствует или маршрут ведёт в VPN'
            failures=$((failures + 1))
        fi
    else
        echo 'Endpoint: UNKNOWN — фактический endpoint недоступен'
        unknown=$((unknown + 1))
    fi
    if [[ "$mode" == diagnose ]] && (( owned )); then
        actual=$(effective_tunnel_mtu || true)
        echo "MTU: настроено=$WG_MTU, фактически=${actual:-UNKNOWN}"
        if recommended=$(recommended_awg_mtu); then
            echo "MTU: оценка underlay минус 80 = $recommended; это не измерение PMTU"
            if is_uint_between "$actual" 1 65535 && (( actual > recommended )); then
                echo 'MTU: WARN — фактическое значение выше оценки'
            fi
        fi
    fi
    if (( proxy_ready )) && http_proxy_healthy; then echo 'HTTP proxy: OK (2xx)'; else echo 'HTTP proxy: FAIL'; failures=$((failures + 1)); fi
    if (( proxy_ready )) && socks_proxy_healthy; then echo 'SOCKS proxy: OK (2xx)'; else echo 'SOCKS proxy: FAIL'; failures=$((failures + 1)); fi
    # Check after traffic: an idle peer can legitimately have an old handshake.
    if (( owned )) && latest=$(run_privileged awg show "$WG_INTERFACE" latest-handshakes 2>/dev/null); then
        latest=$(awk -v key="$PUBLIC_KEY" '$1 == key {print $2; exit}' <<< "$latest")
        now=$(date +%s)
        if is_uint_between "$latest" 1 4294967295 && (( latest <= now )); then
            age=$((now - latest))
            echo "Handshake: $age секунд назад"
            if (( age > 180 )); then echo 'Handshake: FAIL — устарел после проверки трафиком'; failures=$((failures + 1)); fi
        else
            echo 'Handshake: FAIL — отсутствует или некорректная отметка времени'
            failures=$((failures + 1))
        fi
    else
        echo 'Handshake: UNKNOWN — недоступен'
        unknown=$((unknown + 1))
    fi
    (( failures == 0 )) || return 1
    (( unknown == 0 )) || return 2
    return 0
}
