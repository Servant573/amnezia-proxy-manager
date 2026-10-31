#!/bin/bash

# VPN preparation; lifecycle primitives live in tunnel.sh.
vpn_prepare_endpoint() {
    parse_endpoint
    [[ "$ENDPOINT_HOST" != *:* && "$ENDPOINT" != \[* ]] || die "IPv6 ENDPOINT не поддерживается"

    if ! ENDPOINT_IPS=$(resolve_ipv4_host "$ENDPOINT_HOST"); then
        die "Не удалось получить IPv4 endpoint $ENDPOINT_HOST: IPv6-only endpoint не поддерживается"
    fi
    ENDPOINT_CONNECT_HOST="${ENDPOINT_IPS%% *}"
    ENDPOINT_IPS="$ENDPOINT_CONNECT_HOST"
    log INFO "Endpoint $ENDPOINT_HOST закреплён за IPv4 $ENDPOINT_CONNECT_HOST на время запуска"
}

# Every privileged handshake operation shares a monotonic connection deadline.
vpn_connect_command() {
    local remaining=$((vpn_deadline - SECONDS))
    (( remaining > 0 )) || return 124
    sudo -n timeout --kill-after=1 "$remaining" awg "$@"
}

vpn_wait_connected() {
    local vpn_deadline=$((SECONDS + VPN_CONNECT_TIMEOUT))
    local started=${VPN_STARTED_AT:-$(date +%s)} output latest now connected=0
    log INFO "Ожидаю VPN handshake с $ENDPOINT_CONNECT_HOST:$ENDPOINT_PORT (до ${VPN_CONNECT_TIMEOUT} с)..."
    # Force an authenticated keepalive without requiring DNS, ICMP or a public
    # HTTP service inside AllowedIPs. Restore the user's interval afterwards.
    if ! vpn_connect_command set "$WG_INTERFACE" peer "$PUBLIC_KEY" persistent-keepalive 0 ||
       ! vpn_connect_command set "$WG_INTERFACE" peer "$PUBLIC_KEY" persistent-keepalive 1; then
        log ERR "Не удалось инициировать VPN handshake; проверьте sudo и awg"
    else
        while (( SECONDS < vpn_deadline )); do
            check_stop_requested
            if ! output=$(vpn_connect_command show "$WG_INTERFACE" latest-handshakes); then
                log ERR "Не удалось прочитать VPN handshake; интерфейс исчез или awg/sudo недоступен"
                break
            fi
            latest=$(awk -v peer="$PUBLIC_KEY" '$1 == peer { print $2; exit }' <<< "$output")
            now=$(date +%s)
            if is_uint_between "$latest" 1 4294967295 && (( latest >= started && latest <= now )); then
                connected=1
                break
            fi
            sleep 1
        done
    fi
    if ! run_privileged awg set "$WG_INTERFACE" peer "$PUBLIC_KEY" persistent-keepalive "$PERSISTENTKEEPALIVE"; then
        log ERR "Не удалось восстановить PersistentKeepalive; запуск VPN отменён"
        return 1
    fi
    if (( ! connected )); then
        log ERR "VPN не подключён: нет успешного handshake с $ENDPOINT_CONNECT_HOST:$ENDPOINT_PORT за ${VPN_CONNECT_TIMEOUT} с. Проверьте доступность сервера, UDP-порт, ключи и параметры обфускации."
        return 1
    fi
    log OK "VPN подключён: handshake с сервером подтверждён"
}
