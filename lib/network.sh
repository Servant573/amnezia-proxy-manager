#!/bin/bash

is_ipv4() {
    local value="$1" a b c d extra octet
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

    if ! PROXY_IPS=$(resolve_ipv4_host "$PROXY_HOST"); then
        die "Не удалось получить IPv4-адрес upstream-прокси: $PROXY_HOST"
    fi
    PROXY_CONNECT_HOST="${PROXY_IPS%% *}"

    if ENDPOINT_IPS=$(resolve_ipv4_host "$ENDPOINT_HOST"); then
        :
    else
        ENDPOINT_IPS=""
        log WARN "Не удалось заранее получить IPv4 endpoint $ENDPOINT_HOST; проверка маршрута будет ограничена"
    fi

    if [[ "$PROXY_CONNECT_HOST" != "$PROXY_HOST" ]]; then
        log INFO "Upstream $PROXY_HOST закреплён за IPv4 $PROXY_CONNECT_HOST на время запуска"
    fi
}

build_allowed_ips() {
    [[ -n "${PROXY_IPS:-}" ]] || prepare_network_targets

    local tmp raw line ip dns_entry
    tmp=$(mktemp "${ALLOWED_IPS_CACHE}.XXXXXX")

    for ip in $PROXY_IPS; do
        printf '%s/32\n' "$ip" >> "$tmp"
    done
    for dns_entry in ${DNS//,/ }; do
        if is_ipv4 "$dns_entry"; then
            printf '%s/32\n' "$dns_entry" >> "$tmp"
            log INFO "DNS $dns_entry добавлен в AllowedIPs"
        fi
    done

    if [[ -n "${IPLIST_URLS:-}" ]]; then
        local url
        for url in $IPLIST_URLS; do
            log INFO "Скачиваю список: $url"
            if raw=$(curl -fsSL --proto '=https' --max-time 45 --connect-timeout 10 "$url"); then
                printf '%s\n' "$raw" >> "$tmp"
                log OK "Список загружен"
            else
                log WARN "Не удалось скачать: $url"
            fi
        done
    else
        log WARN "IPLIST_URLS пуст — в туннель пойдёт только прокси"
    fi

    ALLOWED_IPS=$(
        while IFS= read -r line; do
            line="${line//$'\r'/}"
            line="${line%%#*}"
            line=$(trim "$line")
            is_ipv4_cidr "$line" || continue
            printf '%s\n' "$line"
        done < "$tmp" | sort -u | paste -sd, -
    )

    local count
    count=$(echo "$ALLOWED_IPS" | tr ',' '\n' | grep -c . || true)
    log INFO "AllowedIPs: ${count} валидных IPv4-префиксов"

    if [[ -z "$ALLOWED_IPS" ]]; then
        rm -f "$tmp"
        die "AllowedIPs пустой — проверь IPLIST_URLS и сеть"
    fi

    echo "$ALLOWED_IPS" | tr ',' '\n' > "$ALLOWED_IPS_CACHE"
    rm -f "$tmp"
}
