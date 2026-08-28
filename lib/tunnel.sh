#!/bin/bash

check_tunnel_deps() {
    command -v awg-quick >/dev/null 2>&1 || die "awg-quick не найден. Установи amneziawg-tools"
    command -v awg       >/dev/null 2>&1 || die "awg не найден. Установи amneziawg-tools"
    command -v ip       >/dev/null 2>&1 || die "iproute2 не найден"
    command -v sudo     >/dev/null 2>&1 || die "sudo не найден"
}

is_tunnel_up() {
    ip link show "$WG_INTERFACE" &>/dev/null
}

generate_wg_config() {
    log INFO "Генерирую временный конфиг AmneziaWG"

    {
        cat <<EOF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${ADDRESS}
EOF
        if [[ -n "$WG_MTU" && "$WG_MTU" != "auto" ]]; then
            echo "MTU = ${WG_MTU}"
        fi
        [[ -n "$DNS" ]] && echo "DNS = ${DNS}"
        cat <<EOF
Jc = ${Jc}
Jmin = ${Jmin}
Jmax = ${Jmax}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
EOF

        [[ -n "${I1:-}" ]] && echo "I1 = ${I1}"
        [[ -n "${I2:-}" ]] && echo "I2 = ${I2}"
        [[ -n "${I3:-}" ]] && echo "I3 = ${I3}"
        [[ -n "${I4:-}" ]] && echo "I4 = ${I4}"
        [[ -n "${I5:-}" ]] && echo "I5 = ${I5}"

        cat <<EOF

[Peer]
PublicKey = ${PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = ${PERSISTENTKEEPALIVE}
EOF
    } > "$WG_TMP_CONF"

    chmod 600 "$WG_TMP_CONF"
}

route_for_ipv4() {
    ip -4 route get "$1" 2>/dev/null | head -1
}

route_uses_interface() {
    local route="$1" interface="$2"
    [[ " $route " == *" dev $interface "* ]]
}

verify_tunnel_routes() {
    local ip route
    for ip in ${ENDPOINT_IPS:-}; do
        route=$(route_for_ipv4 "$ip") || die "Нет маршрута к endpoint $ip"
        if route_uses_interface "$route" "$WG_INTERFACE"; then
            die "Маршрут к endpoint $ip попал в $WG_INTERFACE — обнаружена VPN-петля"
        fi
    done

    route=$(route_for_ipv4 "$PROXY_CONNECT_HOST") || die "Нет маршрута к upstream-прокси $PROXY_CONNECT_HOST"
    if ! route_uses_interface "$route" "$WG_INTERFACE"; then
        die "Upstream-прокси $PROXY_CONNECT_HOST маршрутизируется вне $WG_INTERFACE"
    fi
    log INFO "Маршрут к upstream: $route"
}

underlay_mtu_for_ipv4() {
    local ip="$1" route dev mtu
    route=$(route_for_ipv4 "$ip") || return 1
    mtu=$(awk '{for (i=1; i<=NF; i++) if ($i == "mtu") {print $(i+1); exit}}' <<< "$route")
    if [[ "$mtu" =~ ^[0-9]+$ ]]; then
        printf '%s' "$mtu"
        return 0
    fi
    dev=$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$route")
    [[ -n "$dev" ]] || return 1
    mtu=$(ip -o link show dev "$dev" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "mtu") {print $(i+1); exit}}')
    [[ "$mtu" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$mtu"
}

recommended_awg_mtu() {
    local ip underlay
    ip="${ENDPOINT_IPS%% *}"
    [[ -n "$ip" ]] || return 1
    underlay=$(underlay_mtu_for_ipv4 "$ip") || return 1
    (( underlay > 80 )) || return 1
    printf '%s' "$((underlay - 80))"
}

effective_tunnel_mtu() {
    ip -o link show dev "$WG_INTERFACE" 2>/dev/null \
        | awk '{for (i=1; i<=NF; i++) if ($i == "mtu") {print $(i+1); exit}}'
}

start_tunnel() {
    if is_tunnel_up; then
        log WARN "Интерфейс $WG_INTERFACE уже существует — останавливаю..."
        sudo awg-quick down "$WG_TMP_CONF" 2>/dev/null || true
        sudo awg-quick down "$WG_INTERFACE" 2>/dev/null || true
        sudo ip link delete "$WG_INTERFACE" 2>/dev/null || true
        sleep 0.8
    fi

    generate_wg_config
    log INFO "Поднимаю AmneziaWG ($WG_INTERFACE)..."
    if ! sudo awg-quick up "$WG_TMP_CONF"; then
        die "awg-quick up завершился с ошибкой"
    fi

    sleep 1
    if is_tunnel_up; then
        log OK "Туннель $WG_INTERFACE поднят"
        verify_tunnel_routes
    else
        die "Интерфейс $WG_INTERFACE не появился"
    fi
}

stop_tunnel() {
    log INFO "Останавливаю туннель $WG_INTERFACE..."
    sudo awg-quick down "$WG_TMP_CONF" 2>/dev/null || true
    sudo awg-quick down "$WG_INTERFACE" 2>/dev/null || true
    sudo ip link delete "$WG_INTERFACE" 2>/dev/null || true
    rm -f "$WG_TMP_CONF"
    log OK "Туннель остановлен"
}
