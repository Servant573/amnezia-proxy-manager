#!/bin/bash

is_ipv4() {
    local value="$1" a b c d extra octet
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r a b c d extra <<< "$value"
    [[ -z "${extra:-}" && -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        ((${#octet} <= 3)) || return 1
        [[ "$octet" == "0" || "$octet" != 0* ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

is_ipv4_cidr() {
    local value="$1" ip prefix
    [[ "$value" == */* ]] || return 1
    ip="${value%/*}"
    prefix="${value##*/}"
    is_ipv4 "$ip" \
        && [[ "$prefix" =~ ^[0-9]+$ ]] \
        && ((${#prefix} <= 2)) \
        && [[ "$prefix" == "0" || "$prefix" != 0* ]] \
        && (( 10#$prefix <= 32 ))
}

resolve_ipv4_host() {
    local host="$1" candidate
    local -a ips=()

    if is_ipv4 "$host"; then
        printf '%s' "$host"
        return 0
    fi

    while read -r candidate; do
        is_ipv4 "$candidate" || continue
        if [[ " ${ips[*]:-} " != *" $candidate "* ]]; then
            ips+=("$candidate")
        fi
    done < <(getent ahostsv4 "$host" 2>/dev/null | awk '$2 == "STREAM" { print $1 }')

    ((${#ips[@]} > 0)) || return 1
    printf '%s' "${ips[*]}"
}

parse_endpoint() {
    if [[ "$ENDPOINT" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        ENDPOINT_HOST="${BASH_REMATCH[1]}"
        ENDPOINT_PORT="${BASH_REMATCH[2]}"
    elif [[ "$ENDPOINT" =~ ^([^:]+):([0-9]+)$ ]]; then
        ENDPOINT_HOST="${BASH_REMATCH[1]}"
        ENDPOINT_PORT="${BASH_REMATCH[2]}"
    else
        die "Не удалось распарсить ENDPOINT. Ожидается host:port"
    fi
}

prepare_network_targets() {
    parse_endpoint
    [[ "$ENDPOINT_HOST" != *:* && "$ENDPOINT" != \[* ]] || die "IPv6 ENDPOINT не поддерживается"

    if ! PROXY_IPS=$(resolve_ipv4_host "$PROXY_HOST"); then
        die "Не удалось получить IPv4-адрес upstream-прокси: $PROXY_HOST"
    fi
    PROXY_CONNECT_HOST="${PROXY_IPS%% *}"

    if ! ENDPOINT_IPS=$(resolve_ipv4_host "$ENDPOINT_HOST"); then
        die "Не удалось получить IPv4 endpoint $ENDPOINT_HOST: IPv6-only endpoint не поддерживается"
    fi
    ENDPOINT_CONNECT_HOST="${ENDPOINT_IPS%% *}"
    ENDPOINT_IPS="$ENDPOINT_CONNECT_HOST"
    log INFO "Endpoint $ENDPOINT_HOST закреплён за IPv4 $ENDPOINT_CONNECT_HOST на время запуска"

    if [[ "$PROXY_CONNECT_HOST" != "$PROXY_HOST" ]]; then
        log INFO "Upstream $PROXY_HOST закреплён за IPv4 $PROXY_CONNECT_HOST на время запуска"
    fi
}

build_allowed_ips() {
    [[ -n "${PROXY_IPS:-}" ]] || prepare_network_targets

    local tmp raw line ip dns_entry url item count rejected
    tmp=$(mktemp "${ALLOWED_IPS_CACHE}.XXXXXX")
    if [[ -z "$(trim "${ALLOWED_IPS:-}")" && -z "$(trim "${IPLIST_URLS:-}")" ]]; then
        printf '0.0.0.0/0\n' >> "$tmp"
        log WARN "Списки маршрутов не заданы: весь IPv4-трафик без более специфичных системных маршрутов пойдёт через VPN"
    else
        for item in ${ALLOWED_IPS//,/ }; do
            if is_ipv4 "$item"; then item="$item/32"; fi
            is_ipv4_cidr "$item" || { rm -f "$tmp"; die "ALLOWED_IPS: некорректный IPv4/CIDR"; }
            [[ "$item" != */0 ]] || item=0.0.0.0/0
            printf '%s\n' "$item" >> "$tmp"
        done
        for url in $IPLIST_URLS; do
            log INFO "Скачиваю список: $url"
            if ! raw=$(curl -q -fsSL --proto '=https' --proto-redir '=https' --max-time 45 --connect-timeout 10 -- "$url"); then
                rm -f "$tmp"
                die "Не удалось скачать список маршрутов: $url"
            fi
            count=0; rejected=0
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line//$'\r'/}"
                line="${line%%#*}"
                for item in ${line//,/ }; do
                    if is_ipv4 "$item"; then item="$item/32"; fi
                    if is_ipv4_cidr "$item"; then
                        [[ "$item" != */0 ]] || item=0.0.0.0/0
                        printf '%s\n' "$item" >> "$tmp"
                        count=$((count + 1))
                    else
                        rejected=$((rejected + 1))
                    fi
                done
            done <<< "$raw"
            (( count > 0 )) || { rm -f "$tmp"; die "Список маршрутов не содержит валидных IPv4/CIDR: $url"; }
            (( rejected == 0 )) || log WARN "В списке отброшено невалидных записей: $rejected"
            log OK "Список загружен: $count IPv4-префиксов"
        done
        for ip in $PROXY_IPS; do
            printf '%s/32\n' "$ip" >> "$tmp"
        done
        for dns_entry in ${DNS//,/ }; do
            if is_ipv4 "$dns_entry"; then
                printf '%s/32\n' "$dns_entry" >> "$tmp"
                log INFO "DNS $dns_entry добавлен в AllowedIPs"
            fi
        done
    fi

    ALLOWED_IPS=$(LC_ALL=C sort -u "$tmp" | paste -sd, -)
    # An explicit default route has the same full-tunnel semantics.
    if [[ ",$ALLOWED_IPS," == *,0.0.0.0/0,* ]]; then ALLOWED_IPS=0.0.0.0/0; fi

    count=$(echo "$ALLOWED_IPS" | tr ',' '\n' | grep -c . || true)
    log INFO "AllowedIPs: ${count} валидных IPv4-префиксов"

    if [[ -z "$ALLOWED_IPS" ]]; then
        rm -f "$tmp"
        die "AllowedIPs пустой — проверь IPLIST_URLS и сеть"
    fi

    printf '%s\n' "$ALLOWED_IPS" | tr ',' '\n' > "$tmp"
    mv -f -- "$tmp" "$ALLOWED_IPS_CACHE"
}
