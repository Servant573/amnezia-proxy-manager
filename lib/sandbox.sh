#!/bin/bash

# Песочница для AI-агента: отдельный network namespace (виден только loopback
# и veth к 3proxy) + filesystem-изоляция через bwrap (скрыты секретные пути и
# host /proc, /run). Требует уже запущенный стек: start (туннель + 3proxy +
# guard). Default route отсутствует; proxy-трафик идёт через forwarder → 3proxy.
# Host INPUT/FORWARD guard и filesystem allowlist пока требуют доработки.

SANDBOX_OWNED=0
SANDBOX_NETNS_NAME=""
SANDBOX_HOST_IF="apm0"
SANDBOX_NS_IF="apm1"
SANDBOX_HOST_IP=""
SANDBOX_NS_IP=""
SANDBOX_HTTP_PORT=""
SANDBOX_SOCKS_PORT=""
SANDBOX_LOCK_FD=""
SANDBOX_NS_ID="-"
SANDBOX_HOST_INDEX="-"
SANDBOX_PEER_INDEX="-"
SANDBOX_AGENT_PID=""
SANDBOX_AGENT_ID=""

sandbox_acquire_lock() {
    exec {SANDBOX_LOCK_FD}>"${RUNTIME_DIR}/sandbox.lock" || return 1
    if ! flock -n "$SANDBOX_LOCK_FD"; then
        exec {SANDBOX_LOCK_FD}>&-
        SANDBOX_LOCK_FD=""
        log ERR "Sandbox занят другой операцией или активным run"
        return 1
    fi
}

sandbox_release_lock() {
    if [[ -n "$SANDBOX_LOCK_FD" ]]; then
        exec {SANDBOX_LOCK_FD}>&-
        SANDBOX_LOCK_FD=""
    fi
}

# Status 1 means absent; status 2 means identity could not be read.
sandbox_namespace_identity() {
    [[ -e "/run/netns/$1" ]] || return 1
    stat -Lc '%d:%i' -- "/run/netns/$1" || return 2
}

sandbox_link_identity() {
    [[ -e "/sys/class/net/$1" ]] || return 1
    interface_index "$1" || return 2
}

sandbox_write_owner() {
    local tmp identity
    identity=$(process_identity "$$") || return 1
    tmp=$(mktemp "${RUNTIME_DIR}/sandbox-owner.XXXXXX") || return 1
    if ! printf '%s %s %s %s\n%s\n%s\n2 %s %s %s\n' \
        "$SANDBOX_NETNS_NAME" "$SANDBOX_HOST_IF" "$SANDBOX_HOST_IP" \
        "$(cat /proc/sys/kernel/random/boot_id)" "$$" "$identity" \
        "$SANDBOX_NS_ID" "$SANDBOX_HOST_INDEX" "$SANDBOX_PEER_INDEX" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$SANDBOX_FILE" || { rm -f -- "$tmp"; return 1; }
}

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
    local name="$SANDBOX_NETNS_NAME" token status=0
    sandbox_addrs
    sandbox_namespace_identity "$name" >/dev/null || status=$?
    (( status == 1 )) || die "Namespace $name уже существует или недоступен; чужой ресурс не тронут"
    token=$(cat /proc/sys/kernel/random/uuid) || return 1
    token=${token//-/}
    SANDBOX_HOST_IF="ah${token:0:11}"
    SANDBOX_NS_IF="an${token:0:11}"
    SANDBOX_NS_ID=pending
    SANDBOX_HOST_INDEX=-
    SANDBOX_PEER_INDEX=-
    sandbox_write_owner || die "Не удалось сохранить намерение создания sandbox"
    SANDBOX_OWNED=1

    if ! sudo ip netns add "$name"; then
        SANDBOX_NS_ID=-
        sandbox_write_owner || return 1
        die "Не удалось создать network namespace $name"
    fi
    SANDBOX_NS_ID=$(sandbox_namespace_identity "$name") || die "Не удалось определить принадлежность namespace"
    SANDBOX_HOST_INDEX=pending
    SANDBOX_PEER_INDEX=pending
    sandbox_write_owner || die "Не удалось сохранить идентичность namespace"
    if ! sudo ip link add "$SANDBOX_HOST_IF" type veth peer name "$SANDBOX_NS_IF"; then
        SANDBOX_HOST_INDEX=-
        SANDBOX_PEER_INDEX=-
        sandbox_write_owner || return 1
        die "Не удалось создать veth-пару"
    fi
    SANDBOX_HOST_INDEX=$(sandbox_link_identity "$SANDBOX_HOST_IF") || die "Не удалось определить veth ifindex"
    SANDBOX_PEER_INDEX=$(sandbox_link_identity "$SANDBOX_NS_IF") || die "Не удалось определить peer ifindex"
    sandbox_write_owner || die "Не удалось сохранить принадлежность veth"
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
    # Default route отсутствует. Доступ к самому хосту требует отдельного guard;
    # назначение адреса /30 также создаёт connected route.
    sudo ip netns exec "$name" ip route add "${SANDBOX_HOST_IP}/32" dev "$SANDBOX_NS_IF" \
        || { sandbox_netns_destroy; die "Не удалось добавить маршрут в namespace"; }
    log OK "Network namespace $name создан ($SANDBOX_HOST_IP ↔ $SANDBOX_NS_IP, без default-route)"
}

sandbox_netns_destroy() {
    [[ -f "$SANDBOX_FILE" ]] || { SANDBOX_OWNED=0; return 0; }
    local name host_if host_ip boot run_pid run_identity version ns_id host_index peer_index extra
    local actual_ns="" actual_host="" actual_peer="" status peer_if pids
    read -r name host_if host_ip boot < "$SANDBOX_FILE" || return 1
    run_pid=$(sed -n '2p' "$SANDBOX_FILE" 2>/dev/null || true)
    run_identity=$(sed -n '3p' "$SANDBOX_FILE" 2>/dev/null || true)
    [[ "$name" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ && "$name" != . && "$name" != .. ]] \
        || { log ERR "Некорректная запись sandbox; состояние сохранено"; return 1; }
    [[ "$boot" == "$(cat /proc/sys/kernel/random/boot_id)" ]] \
        || { log ERR "Состояние sandbox от другой загрузки; не тронут"; return 1; }
    read -r version ns_id host_index peer_index extra < <(sed -n '4p' "$SANDBOX_FILE") \
        || { log ERR "Старое/повреждённое состояние sandbox; автоматическое удаление запрещено"; return 1; }
    [[ "$version" == 2 && -z "$extra" && "$host_if" =~ ^ah[0-9a-f]{11}$ \
        && "$ns_id" =~ ^(-|pending|[0-9]+:[0-9]+)$ \
        && "$host_index" =~ ^(-|pending|[1-9][0-9]*)$ \
        && "$peer_index" =~ ^(-|pending|[1-9][0-9]*)$ \
        && "$run_pid" =~ ^[1-9][0-9]*$ && -n "$run_identity" ]] \
        || { log ERR "Неподтверждённое/старое состояние sandbox; автоматическое удаление запрещено"; return 1; }
    # Чужой запущенный run не трогаем: его netns может использоваться прямо сейчас.
    if [[ "$run_pid" =~ ^[1-9][0-9]*$ && "$run_pid" != "$$" ]] \
        && same_process_alive "$run_pid" "$run_identity"; then
        log ERR "Sandbox активен (запущен процесс $run_pid); сначала завершите run"
        return 1
    fi
    peer_if="an${host_if#ah}"
    status=0; actual_ns=$(sandbox_namespace_identity "$name") || status=$?
    (( status < 2 )) || return 1
    status=0; actual_host=$(sandbox_link_identity "$host_if") || status=$?
    (( status < 2 )) || return 1
    status=0; actual_peer=$(sandbox_link_identity "$peer_if") || status=$?
    (( status < 2 )) || return 1
    # Never adopt intent-only resources or replacements, even after a crash.
    [[ ( -z "$actual_ns" || "$actual_ns" == "$ns_id" ) \
        && ( -z "$actual_host" || "$actual_host" == "$host_index" ) \
        && ( -z "$actual_peer" || "$actual_peer" == "$peer_index" ) ]] \
        || { log ERR "Принадлежность sandbox не подтверждена; состояние и ресурсы сохранены"; return 1; }
    if [[ -n "$actual_host" ]]; then
        run_privileged ip link del "$host_if" || return 1
    elif [[ -n "$actual_peer" ]]; then
        run_privileged ip link del "$peer_if" || return 1
    fi
    if [[ -n "$actual_ns" ]]; then
        pids=$(run_privileged ip netns pids "$name") || return 1
        [[ -z "$pids" ]] || { log ERR "Namespace ещё занят процессами; повторите stop после их завершения"; return 1; }
        run_privileged ip netns del "$name" \
            || { log ERR "Не удалось удалить namespace $name; повторите stop"; return 1; }
    fi
    rm -f "$SANDBOX_FILE"
    SANDBOX_OWNED=0
    log OK "Sandbox namespace $name удалён"
}

sandbox_start_forwarder() {
    local pid ready="${RUNTIME_DIR}/sandbox-forwarder.ready" attempt
    [[ ! -e "$FW_PID_FILE" ]] || die "Осталось состояние forwarder; сначала выполните stop"
    rm -f -- "$ready"
    prepare_log_for_follow "$SANDBOX_LOG_FILE" || die "Небезопасный файл лога sandbox: $SANDBOX_LOG_FILE"
    (
        [[ -z "$SANDBOX_LOCK_FD" ]] || exec {SANDBOX_LOCK_FD}>&-
        exec python3 "$PROJECT_ROOT/lib/sandbox_forwarder.py" --ready "$ready" --log "$SANDBOX_LOG_FILE" \
        "${SANDBOX_HOST_IP}:${SANDBOX_HTTP_PORT}=127.0.0.1:${SANDBOX_HTTP_PORT}" \
        "${SANDBOX_HOST_IP}:${SANDBOX_SOCKS_PORT}=127.0.0.1:${SANDBOX_SOCKS_PORT}"
    ) &
    pid=$!
    if ! write_process_record "$FW_PID_FILE" "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        die "Не удалось записать идентичность forwarder"
    fi
    for (( attempt=0; attempt<50; attempt++ )); do
        process_record_matches "$FW_PID_FILE" "$pid" && kill -0 "$pid" 2>/dev/null \
            || die "Forwarder завершился до READY"
        if [[ -f "$ready" && "$(<"$ready")" == "$pid" ]]; then break; fi
        sleep 0.1
    done
    (( attempt < 50 )) || die "Forwarder не подтвердил READY"
    log INFO "Forwarder запущен (PID $pid): $SANDBOX_HOST_IP → 127.0.0.1, лог $SANDBOX_LOG_FILE"
}

sandbox_stop_forwarder() {
    [[ -f "$FW_PID_FILE" ]] || return 0
    local pid identity
    pid=$(read_pid "$FW_PID_FILE") || return 1
    identity=$(sed -n '2p' "$FW_PID_FILE") || return 1
    [[ -n "$identity" ]] || { log ERR "Старый PID forwarder без идентичности; сигнал не отправлен"; return 1; }
    if same_process_alive "$pid" "$identity"; then
        process_cmdline_contains "$pid" "$PROJECT_ROOT/lib/sandbox_forwarder.py" || return 1
        kill -TERM "$pid" || { ! same_process_alive "$pid" "$identity" || return 1; }
        wait_for_process_exit "$pid" "$identity" 30 || return 1
        wait "$pid" 2>/dev/null || true
    fi
    rm -f "$FW_PID_FILE"
    rm -f -- "${RUNTIME_DIR}/sandbox-forwarder.ready"
}

sandbox_stop() {
    if [[ -n "$SANDBOX_LOCK_FD" ]]; then
        sandbox_netns_destroy && sandbox_stop_forwarder
        return $?
    fi
    sandbox_acquire_lock || return 1
    local rc=0
    sandbox_netns_destroy && sandbox_stop_forwarder || rc=1
    sandbox_release_lock
    return "$rc"
}

sandbox_verify() {
    local links routes exit_ip
    links=$(sudo ip netns exec "$SANDBOX_NETNS_NAME" ip -o link show 2>/dev/null | wc -l)
    (( links == 2 )) || die "Изоляция нарушена: в namespace $links интерфейсов вместо 2"
    routes=$(sudo ip netns exec "$SANDBOX_NETNS_NAME" ip route show 2>/dev/null)
    [[ "$routes" != *"default"* ]] || die "Изоляция нарушена: в namespace есть default-route"
    if ! sudo ip netns exec "$SANDBOX_NETNS_NAME" curl -q -fsS --noproxy '' \
        --connect-timeout 3 --max-time 10 --output /dev/null \
        --proxy "http://${SANDBOX_HOST_IP}:${SANDBOX_HTTP_PORT}" "$HEALTHCHECK_URL"; then
        die "Forwarder или прокси недоступны из namespace"
    fi
    if ! sudo ip netns exec "$SANDBOX_NETNS_NAME" curl -q -fsS --noproxy '' \
        --connect-timeout 3 --max-time 10 --output /dev/null \
        --proxy "socks5h://${SANDBOX_HOST_IP}:${SANDBOX_SOCKS_PORT}" "$HEALTHCHECK_URL"; then
        die "SOCKS forwarder или прокси недоступны из namespace"
    fi
    log OK "Изоляция проверена: 2 интерфейса, без default-route, прокси доступен"
    if [[ -n "$SANDBOX_EXPECTED_EXIT_IP" ]]; then
        if ! exit_ip=$(sudo ip netns exec "$SANDBOX_NETNS_NAME" curl -q -fsS --noproxy '' \
            --connect-timeout 3 --max-time 10 \
            --proxy "http://${SANDBOX_HOST_IP}:${SANDBOX_HTTP_PORT}" "$HEALTHCHECK_URL"); then
            die "Не удалось определить выходной IP из namespace"
        fi
        [[ "$exit_ip" == "$SANDBOX_EXPECTED_EXIT_IP" ]] \
            || die "Выходной IP $exit_ip не совпал с SANDBOX_EXPECTED_EXIT_IP ($SANDBOX_EXPECTED_EXIT_IP)"
        log OK "Выходной IP подтверждён: $exit_ip"
    fi
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
    BWRAP_ARGS+=( --setenv NO_PROXY "$SANDBOX_NO_PROXY" --setenv no_proxy "$SANDBOX_NO_PROXY" )
    # Это предпочтение порядка DNS, а не IPv6 security boundary.
    BWRAP_ARGS+=( --setenv NODE_OPTIONS "${NODE_OPTIONS:-}${NODE_OPTIONS:+ }--dns-result-order=ipv4first" )
}

sandbox_run_agent() {
    # Called only in a background child; do not leak the session lock fd.
    [[ -z "$SANDBOX_LOCK_FD" ]] || exec {SANDBOX_LOCK_FD}>&-
    exec sudo ip netns exec "$SANDBOX_NETNS_NAME" \
        setpriv --reuid="$UID" --regid="$(id -g)" --clear-groups -- \
        bwrap "${BWRAP_ARGS[@]}" -- "$@"
}

sandbox_run_cleanup() {
    local rc=0
    if (( SANDBOX_OWNED )); then
        if [[ -n "$SANDBOX_AGENT_PID" && -n "$SANDBOX_AGENT_ID" ]] \
            && same_process_alive "$SANDBOX_AGENT_PID" "$SANDBOX_AGENT_ID"; then
            kill -TERM "$SANDBOX_AGENT_PID" 2>/dev/null || rc=1
            if wait_for_process_exit "$SANDBOX_AGENT_PID" "$SANDBOX_AGENT_ID" 30; then
                wait "$SANDBOX_AGENT_PID" 2>/dev/null || true
            else
                rc=1
            fi
        fi
        sandbox_stop_forwarder || rc=1
        sandbox_netns_destroy || rc=1
    fi
    release_lock
    sandbox_release_lock
    if (( rc )); then log ERR "Очистка sandbox не завершена; состояние сохранено для stop"; fi
    return "$rc"
}

do_run() {
    load_config
    check_sandbox_deps
    sandbox_acquire_lock || die "Не удалось заблокировать sandbox"
    trap sandbox_run_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    acquire_lock
    is_proxy_running || die "3proxy не запущен; сначала выполните start"

    # Активный интерфейс берём из состояния запуска, а не из конфига.
    if [[ -r "$TUNNEL_OWNER_FILE" ]]; then
        local owner_iface
        read -r owner_iface _ _ < "$TUNNEL_OWNER_FILE" || true
        [[ -n "$owner_iface" ]] && WG_INTERFACE="$owner_iface"
    fi
    is_tunnel_up || die "Туннель не поднят; сначала выполните start"

    read_active_proxy_ports
    [[ ! -e "$FW_PID_FILE" ]] || die "Осталось состояние forwarder; сначала выполните stop"
    sandbox_netns_create
    sandbox_start_forwarder
    release_lock

    sandbox_verify
    sandbox_build_bwrap

    log INFO "Sandbox активен: netns=$SANDBOX_NETNS_NAME, proxy=$SANDBOX_HOST_IP:$SANDBOX_HTTP_PORT"
    local rc=0
    sandbox_run_agent "$@" &
    SANDBOX_AGENT_PID=$!
    SANDBOX_AGENT_ID=$(process_identity "$SANDBOX_AGENT_PID") || SANDBOX_AGENT_ID=""
    wait "$SANDBOX_AGENT_PID" || rc=$?
    SANDBOX_AGENT_PID=""
    SANDBOX_AGENT_ID=""
    return "$rc"
}
