#!/bin/bash

# Песочница для AI-агента: отдельный network namespace (виден только loopback
# и veth к 3proxy) + filesystem-изоляция через bwrap (скрыты секретные пути и
# host /proc, /run). Требует уже запущенный стек: start (туннель + 3proxy +
# guard). Весь трафик агента проходит строго через forwarder → 3proxy → VPN.

SANDBOX_OWNED=0
SANDBOX_NETNS_NAME=""
SANDBOX_HOST_IF="apm0"
SANDBOX_NS_IF="apm1"
SANDBOX_HOST_IP=""
SANDBOX_NS_IP=""
SANDBOX_HTTP_PORT=""
SANDBOX_SOCKS_PORT=""

check_sandbox_deps() {
    command -v sudo    >/dev/null 2>&1 || die "sudo не найден"
    command -v ip      >/dev/null 2>&1 || die "iproute2 не найден"
    command -v bwrap   >/dev/null 2>&1 || die "bwrap не найден (bubblewrap)"
    command -v python3 >/dev/null 2>&1 || die "python3 не найден"
    command -v setpriv >/dev/null 2>&1 || die "setpriv не найден (util-linux)"
    command -v curl    >/dev/null 2>&1 || die "curl не найден"
}

ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%d' $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

ipv4_from_int() {
    local n="$1"
    printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
}

# /30: host = base+1, namespace = base+2.
sandbox_addrs() {
    local ip base
    ip="${SANDBOX_VETH_SUBNET%/*}"
    base=$(ipv4_to_int "$ip")
    SANDBOX_HOST_IP=$(ipv4_from_int $((base + 1)))
    SANDBOX_NS_IP=$(ipv4_from_int $((base + 2)))
}

# Активные порты читаем из runtime-конфига 3proxy, а не из пользовательского
# конфига: правки конфига после start не должны менять цель forwarder.
read_active_proxy_ports() {
    local http socks
    [[ -r "$PROXY_CFG" ]] || die "Runtime-конфиг 3proxy не найден; сначала выполните start"
    http=$(awk '$1 == "proxy" {for(i=2;i<=NF;i++) if ($i ~ /^-p[0-9]+$/) {print substr($i,3); exit}}' "$PROXY_CFG")
    socks=$(awk '$1 == "socks" {for(i=2;i<=NF;i++) if ($i ~ /^-p[0-9]+$/) {print substr($i,3); exit}}' "$PROXY_CFG")
    is_uint_between "$http" 1 65535 && is_uint_between "$socks" 1 65535 \
        || die "Не удалось определить активные порты 3proxy из $PROXY_CFG"
    SANDBOX_HTTP_PORT="$http"
    SANDBOX_SOCKS_PORT="$socks"
}

sandbox_netns_create() {
    [[ ! -e "$SANDBOX_FILE" ]] || die "Осталось состояние sandbox; сначала выполните stop"
    local name="$SANDBOX_NETNS_NAME" boot run_identity
    sandbox_addrs
    boot=$(cat /proc/sys/kernel/random/boot_id)
    run_identity=$(process_identity "$$") || die "Не удалось определить идентификатор процесса"
    # Намерение сохраняется до действий: SIGKILL не должен оставлять netns без
    # записи для восстановления (тот же паттерн, что и в lib/guard.sh).
    printf '%s %s %s %s\n%s\n%s\n' \
        "$name" "$SANDBOX_HOST_IF" "$SANDBOX_HOST_IP" "$boot" "$$" "$run_identity" > "$SANDBOX_FILE"
    SANDBOX_OWNED=1

    sudo ip netns add "$name" \
        || { sandbox_netns_destroy; die "Не удалось создать network namespace $name"; }
    sudo ip link add "$SANDBOX_HOST_IF" type veth peer name "$SANDBOX_NS_IF" \
        || { sandbox_netns_destroy; die "Не удалось создать veth-пару"; }
    sudo ip link set "$SANDBOX_NS_IF" netns "$name" \
        || { sandbox_netns_destroy; die "Не удалось перенести veth в namespace"; }
    sudo ip addr add "${SANDBOX_HOST_IP}/30" dev "$SANDBOX_HOST_IF" \
        || { sandbox_netns_destroy; die "Не удалось назначить адрес host-стороне veth"; }
    sudo ip link set "$SANDBOX_HOST_IF" up \
        || { sandbox_netns_destroy; die "Не удалось поднять host-сторону veth"; }
    sudo ip netns exec "$name" ip link set lo up \
        || { sandbox_netns_destroy; die "Не удалось поднять lo в namespace"; }
    sudo ip netns exec "$name" ip addr add "${SANDBOX_NS_IP}/30" dev "$SANDBOX_NS_IF" \
        || { sandbox_netns_destroy; die "Не удалось назначить адрес в namespace"; }
    sudo ip netns exec "$name" ip link set "$SANDBOX_NS_IF" up \
        || { sandbox_netns_destroy; die "Не удалось поднять veth в namespace"; }
    # Единственный маршрут — к host-стороне veth. Default-route отсутствует,
    # поэтому агент физически не может выйти за пределы forwarder→прокси→VPN.
    sudo ip netns exec "$name" ip route add "${SANDBOX_HOST_IP}/32" dev "$SANDBOX_NS_IF" \
        || { sandbox_netns_destroy; die "Не удалось добавить маршрут в namespace"; }
    log OK "Network namespace $name создан ($SANDBOX_HOST_IP ↔ $SANDBOX_NS_IP, без default-route)"
}

sandbox_netns_destroy() {
    [[ -f "$SANDBOX_FILE" ]] || { SANDBOX_OWNED=0; return 0; }
    local name host_if host_ip boot run_pid run_identity
    read -r name host_if host_ip boot < "$SANDBOX_FILE" || { rm -f "$SANDBOX_FILE"; return 1; }
    run_pid=$(sed -n '2p' "$SANDBOX_FILE" 2>/dev/null || true)
    run_identity=$(sed -n '3p' "$SANDBOX_FILE" 2>/dev/null || true)
    [[ "$name" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ && "$name" != . && "$name" != .. ]] \
        || { log ERR "Некорректная запись sandbox; состояние сохранено"; return 1; }
    [[ "$boot" == "$(cat /proc/sys/kernel/random/boot_id)" ]] \
        || { log ERR "Состояние sandbox от другой загрузки; не тронут"; return 1; }
    # Чужой запущенный run не трогаем: его netns может использоваться прямо сейчас.
    if [[ "$run_pid" =~ ^[1-9][0-9]*$ && "$run_pid" != "$$" ]] \
        && same_process_alive "$run_pid" "$run_identity"; then
        log ERR "Sandbox активен (запущен процесс $run_pid); сначала завершите run"
        return 1
    fi
    if [[ -e "/run/netns/$name" ]]; then
        run_privileged ip netns del "$name" \
            || { log ERR "Не удалось удалить namespace $name; повторите stop"; return 1; }
    fi
    # Удаление netns уничтожает veth внутри; на случай остатка — защитная очистка.
    ip link show "$host_if" >/dev/null 2>&1 && run_privileged ip link del "$host_if" 2>/dev/null || true
    rm -f "$SANDBOX_FILE"
    SANDBOX_OWNED=0
    log OK "Sandbox namespace $name удалён"
}

sandbox_start_forwarder() {
    local pid
    python3 "$PROJECT_ROOT/lib/sandbox_forwarder.py" \
        "${SANDBOX_HOST_IP}:${SANDBOX_HTTP_PORT}=127.0.0.1:${SANDBOX_HTTP_PORT}" \
        "${SANDBOX_HOST_IP}:${SANDBOX_SOCKS_PORT}=127.0.0.1:${SANDBOX_SOCKS_PORT}" &
    pid=$!
    printf '%s\n' "$pid" > "$FW_PID_FILE"
    log INFO "Forwarder запущен (PID $pid): $SANDBOX_HOST_IP → 127.0.0.1"
}

sandbox_stop_forwarder() {
    [[ -f "$FW_PID_FILE" ]] || return 0
    local pid
    read -r pid < "$FW_PID_FILE" || { rm -f "$FW_PID_FILE"; return 0; }
    kill "$pid" 2>/dev/null || true
    rm -f "$FW_PID_FILE"
}

sandbox_verify() {
    local links routes
    links=$(sudo ip netns exec "$SANDBOX_NETNS_NAME" ip -o link show 2>/dev/null | wc -l)
    (( links == 2 )) || die "Изоляция нарушена: в namespace $links интерфейсов вместо 2"
    routes=$(sudo ip netns exec "$SANDBOX_NETNS_NAME" ip route show 2>/dev/null)
    [[ "$routes" != *"default"* ]] || die "Изоляция нарушена: в namespace есть default-route"
    if ! sudo ip netns exec "$SANDBOX_NETNS_NAME" curl -q -fsS --noproxy '' \
        --connect-timeout 3 --max-time 10 --output /dev/null \
        --proxy "http://${SANDBOX_HOST_IP}:${SANDBOX_HTTP_PORT}" "$HEALTHCHECK_URL"; then
        die "Forwarder или прокси недоступны из namespace"
    fi
    log OK "Изоляция проверена: 2 интерфейса, без default-route, прокси доступен"
}

sandbox_build_bwrap() {
    local empty_stub resolv_stub sysdir
    empty_stub="${RUNTIME_DIR}/sandbox-empty"
    resolv_stub="${RUNTIME_DIR}/sandbox-resolv.conf"
    ( umask 077; : > "$empty_stub"; printf 'nameserver 127.0.0.1\n' > "$resolv_stub" ) || return 1

    BWRAP_ARGS=( --die-with-parent --unshare-pid --proc /proc --dev /dev --tmpfs /tmp )
    for sysdir in /usr /bin /sbin /lib /lib64 /etc /opt; do
        [[ -e "$sysdir" ]] && BWRAP_ARGS+=( --ro-bind "$sysdir" "$sysdir" )
    done
    BWRAP_ARGS+=( --bind "$HOME" "$HOME" --bind "$PWD" "$PWD" )

    # Скрыть host-DNS: файл — напрямую, симлинк — по фактическому пути цели.
    if [[ -L /etc/resolv.conf ]]; then
        local target d
        target=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
        if [[ -n "$target" && "$target" != /etc/resolv.conf ]]; then
            d="${target%/*}"
            BWRAP_ARGS+=( --dir "$d" --ro-bind "$resolv_stub" "$target" )
        fi
    elif [[ -f /etc/resolv.conf ]]; then
        BWRAP_ARGS+=( --ro-bind "$resolv_stub" /etc/resolv.conf )
    fi

    # Секретные пути: каталоги — пустой tmpfs, файлы — пустой stub.
    local hide
    for hide in "$CONFIG_FILE" "$LEGACY_CONFIG_FILE" "${HOME}/.ssh" "${HOME}/.aws" \
                "${HOME}/.gnupg" "${HOME}/.config/gcloud" "${HOME}/.azure" "${HOME}/.kube" \
                $SANDBOX_HIDE_PATHS; do
        [[ -n "$hide" ]] || continue
        if [[ -d "$hide" ]]; then
            BWRAP_ARGS+=( --tmpfs "$hide" )
        elif [[ -e "$hide" ]]; then
            BWRAP_ARGS+=( --ro-bind "$empty_stub" "$hide" )
        fi
    done

    BWRAP_ARGS+=( --cap-drop ALL --chdir "$PWD" )
    BWRAP_ARGS+=( --setenv HTTP_PROXY "http://${SANDBOX_HOST_IP}:${SANDBOX_HTTP_PORT}" )
    BWRAP_ARGS+=( --setenv http_proxy "http://${SANDBOX_HOST_IP}:${SANDBOX_HTTP_PORT}" )
    BWRAP_ARGS+=( --setenv HTTPS_PROXY "http://${SANDBOX_HOST_IP}:${SANDBOX_HTTP_PORT}" )
    BWRAP_ARGS+=( --setenv https_proxy "http://${SANDBOX_HOST_IP}:${SANDBOX_HTTP_PORT}" )
    BWRAP_ARGS+=( --setenv ALL_PROXY "socks5h://${SANDBOX_HOST_IP}:${SANDBOX_SOCKS_PORT}" )
    BWRAP_ARGS+=( --setenv all_proxy "socks5h://${SANDBOX_HOST_IP}:${SANDBOX_SOCKS_PORT}" )
    BWRAP_ARGS+=( --setenv NO_PROXY "" --setenv no_proxy "" )
}

sandbox_run_agent() {
    # Войти в netns (root), сбросить привилегии до пользователя, запустить bwrap.
    sudo ip netns exec "$SANDBOX_NETNS_NAME" \
        setpriv --reuid="$UID" --regid="$(id -g)" --clear-groups -- \
        bwrap "${BWRAP_ARGS[@]}" -- "$@"
}

sandbox_run_cleanup() {
    sudo -v 2>/dev/null || true
    sandbox_stop_forwarder
    sandbox_netns_destroy
}

do_run() {
    load_config
    check_sandbox_deps
    is_proxy_running || die "3proxy не запущен; сначала выполните start"

    # Активный интерфейс берём из состояния запуска, а не из конфига.
    if [[ -r "$TUNNEL_OWNER_FILE" ]]; then
        local owner_iface
        read -r owner_iface _ _ < "$TUNNEL_OWNER_FILE" || true
        [[ -n "$owner_iface" ]] && WG_INTERFACE="$owner_iface"
    fi
    is_tunnel_up || die "Туннель не поднят; сначала выполните start"

    read_active_proxy_ports
    sandbox_netns_create
    sandbox_start_forwarder
    trap sandbox_run_cleanup EXIT

    sandbox_verify
    sandbox_build_bwrap

    log INFO "Sandbox активен: netns=$SANDBOX_NETNS_NAME, proxy=$SANDBOX_HOST_IP:$SANDBOX_HTTP_PORT"
    local rc=0
    sandbox_run_agent "$@" || rc=$?
    return "$rc"
}
