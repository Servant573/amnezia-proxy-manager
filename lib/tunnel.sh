#!/bin/bash

TUNNEL_OWNED=0

interface_index() {
    local line index
    line=$(ip -o link show dev "$1") || return 1
    index="${line%%:*}"
    [[ "$index" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$index"
}

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
    local endpoint_ip="${ENDPOINT_CONNECT_HOST:-${ENDPOINT_HOST:-}}"
    is_ipv4 "$endpoint_ip" || die "IPv4 endpoint не подготовлен; генерация AWG-конфига запрещена"

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
Endpoint = ${endpoint_ip}:${ENDPOINT_PORT}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = ${PERSISTENTKEEPALIVE}
EOF
        [[ -z "$PRESHARED_KEY" ]] || printf 'PresharedKey = %s\n' "$PRESHARED_KEY"
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
    [[ -n "${ENDPOINT_IPS:-}" ]] || die "IPv4 endpoint не определён; проверку маршрута нельзя пропустить"
    for ip in ${ENDPOINT_IPS:-}; do
        is_ipv4 "$ip" || die "Проверка маршрута требует IPv4 endpoint"
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
    [[ ! -e "$TUNNEL_OWNER_FILE" ]] || die "Осталось состояние туннеля; сначала выполните stop"
    if is_tunnel_up; then
        die "Интерфейс $WG_INTERFACE уже существует и не будет изменён"
    fi

    generate_wg_config
    log INFO "Поднимаю AmneziaWG ($WG_INTERFACE)..."
    if ! sudo awg-quick up "$WG_TMP_CONF"; then
        die "awg-quick up завершился с ошибкой"
    fi
    local index boot
    index=$(interface_index "$WG_INTERFACE")
    boot=$(cat /proc/sys/kernel/random/boot_id)
    printf '%s %s %s\n' "$WG_INTERFACE" "$index" "$boot" > "$TUNNEL_OWNER_FILE"
    TUNNEL_OWNED=1

    sleep 1
    if is_tunnel_up; then
        log OK "Туннель $WG_INTERFACE поднят"
        verify_tunnel_routes
    else
        die "Интерфейс $WG_INTERFACE не появился"
    fi
}

stop_tunnel() {
    [[ -f "$TUNNEL_OWNER_FILE" ]] || return 0
    local owned_interface owned_index owned_boot current_index
    read -r owned_interface owned_index owned_boot < "$TUNNEL_OWNER_FILE" || return 1
    [[ "$owned_interface" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ && "$owned_interface" != . && "$owned_interface" != .. && "$owned_index" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$owned_boot" == "$(cat /proc/sys/kernel/random/boot_id)" ]] || {
        log ERR "Состояние туннеля от другой загрузки; интерфейс не тронут"; return 1;
    }
    WG_INTERFACE="$owned_interface"
    WG_TMP_CONF="${RUNTIME_DIR}/${owned_interface}.conf"
    if is_tunnel_up; then
        current_index=$(interface_index "$WG_INTERFACE") || return 1
        [[ "$current_index" == "$owned_index" ]] || {
            log ERR "Интерфейс $WG_INTERFACE заменён другим; удаление запрещено"; return 1;
        }
    fi
    log INFO "Останавливаю туннель $WG_INTERFACE..."
    [[ -r "$WG_TMP_CONF" ]] || { log ERR "Конфиг туннеля утрачен; автоматическая очистка небезопасна"; return 1; }
    if is_tunnel_up; then
        run_privileged awg-quick down "$WG_TMP_CONF" || {
            log ERR "Не удалось очистить туннель; проверьте sudo (sudo -v) и повторите stop"; return 1;
        }
        ! is_tunnel_up || return 1
    fi
    # awg-quick suppresses errors from unset_dns/remove_firewall. Check them
    # ourselves, including a retry after the interface has already disappeared.
    local saved_dns prefix="" tables
    saved_dns=$(awk -F= '$1 ~ /^[[:space:]]*DNS[[:space:]]*$/ {print $2}' "$WG_TMP_CONF")
    if [[ -n "$(trim "$saved_dns")" ]]; then
        if [[ -r /etc/resolvconf/interface-order ]]; then
            prefix=$(awk '/^[A-Za-z0-9-]+\*$/ {sub(/\*$/, "."); print; exit}' /etc/resolvconf/interface-order)
        fi
        run_privileged resolvconf -d "$prefix$WG_INTERFACE" -f || {
            log ERR "DNS не очищен; состояние сохранено для повторного stop"; return 1;
        }
    fi
    tables=$(run_privileged nft list tables) || return 1
    if grep -Fxq -e "table ip wg-quick-$WG_INTERFACE" -e "table ip6 wg-quick-$WG_INTERFACE" <<< "$tables"; then
        log ERR "Остались правила awg-quick; требуется проверка администратора, состояние сохранено"
        return 1
    fi
    rm -f "$WG_TMP_CONF" "$TUNNEL_OWNER_FILE"
    TUNNEL_OWNED=0
    log OK "Туннель остановлен"
}
