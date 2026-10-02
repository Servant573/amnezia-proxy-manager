#!/bin/bash

is_uint_between() {
    local value="$1" lower="$2" upper="$3"
    [[ "$value" =~ ^(0|[1-9][0-9]{0,9})$ ]] && (( value >= lower && value <= upper ))
}

is_ipv6() {
    local value="$1" group left right compressed=0
    local -a groups
    [[ "$value" == *:* && "$value" != *:::* ]] || return 1
    if [[ "$value" == *.* ]]; then
        is_ipv4 "${value##*:}" || return 1
        value="${value%:*}:0:0"
    fi
    if [[ "$value" == *::* ]]; then
        compressed=1
        left="${value%%::*}"; right="${value#*::}"
        [[ "$right" != *::* ]] || return 1
        value="${left}${left:+:}${right}"
        value="${value%:}"
    else
        [[ "$value" != :* && "$value" != *: ]] || return 1
    fi
    IFS=: read -r -a groups <<< "$value"
    for group in "${groups[@]}"; do
        [[ "$group" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
    done
    if (( compressed )); then (( ${#groups[@]} < 8 )); else (( ${#groups[@]} == 8 )); fi
}

is_host() {
    local value="$1" label
    local -a labels
    if [[ "$value" =~ ^[0-9.]+$ ]]; then is_ipv4 "$value"; return; fi
    [[ ${#value} -le 253 ]] || return 1
    value="${value%.}"
    [[ -n "$value" && "$value" != .* && "$value" != *..* && "$value" != *. ]] || return 1
    IFS=. read -r -a labels <<< "$value"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

is_https_url() {
    local value="$1" authority host port
    [[ "$value" == https://* && "$value" != *[[:space:][:cntrl:]]* ]] || return 1
    authority="${value#https://}"; authority="${authority%%[/?#]*}"
    [[ -n "$authority" && "$authority" != *@* ]] || return 1
    if [[ "$authority" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
        host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]:-443}"
        is_ipv6 "$host" || return 1
    else
        host="${authority%%:*}"; port=443
        [[ "$authority" != *:* ]] || port="${authority#*:}"
        is_host "$host" || return 1
    fi
    is_uint_between "$port" 1 65535
}

validate_config_values() {
    local key value item lo hi other
    local -a lows=() highs=()
    for key in WG_INTERFACE PRIVATE_KEY ADDRESS PUBLIC_KEY ENDPOINT PROXY_STRING; do
        [[ -n "${!key:-}" ]] || die "$key не задан"
    done
    [[ "$WG_INTERFACE" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ && "$WG_INTERFACE" != . && "$WG_INTERFACE" != .. ]] || die "Недопустимое имя WG_INTERFACE"
    for key in PRIVATE_KEY PUBLIC_KEY PRESHARED_KEY; do
        value="${!key}"
        [[ "$key" != PRESHARED_KEY || -n "$value" ]] || continue
        [[ "$value" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || die "$key: ожидается Base64-ключ длиной 32 байта"
    done
    [[ "$ADDRESS" != ,* && "$ADDRESS" != *, && "$ADDRESS" != *,,* ]] || die "Некорректный список ADDRESS"
    for item in ${ADDRESS//,/ }; do
        is_ipv4_cidr "$item" || die "ADDRESS: поддерживаются только IPv4 CIDR"
    done
    [[ "$DNS" != ,* && "$DNS" != *, && "$DNS" != *,,* ]] || die "Некорректный список DNS"
    for item in ${DNS//,/ }; do
        is_ipv4 "$item" || die "DNS: поддерживаются только IPv4-адреса (или пустое значение)"
    done
    parse_endpoint
    [[ "$ENDPOINT" != \[* && "$ENDPOINT_HOST" != *:* ]] || die "IPv6 ENDPOINT не поддерживается: используйте IPv4 или hostname с A-записью"
    is_host "$ENDPOINT_HOST" || die "Некорректный адрес ENDPOINT"
    is_uint_between "$ENDPOINT_PORT" 1 65535 || die "ENDPOINT: порт должен быть от 1 до 65535"
    IFS=: read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$PROXY_STRING"
    is_host "$PROXY_HOST" || die "Некорректный адрес upstream (IPv4 или hostname)"
    is_uint_between "$PROXY_PORT" 1 65535 || die "Порт upstream должен быть от 1 до 65535"
    [[ -n "$PROXY_USER" && -n "$PROXY_PASS" ]] || die "PROXY_STRING: ожидается host:port:user:password"
    for key in LOCAL_HTTP_PORT LOCAL_SOCKS_PORT; do
        is_uint_between "${!key}" 1 65535 || die "$key должен быть от 1 до 65535"
    done
    [[ "$LOCAL_HTTP_PORT" != "$LOCAL_SOCKS_PORT" ]] || die "HTTP и SOCKS должны использовать разные порты"
    is_uint_between "$PERSISTENTKEEPALIVE" 0 65535 || die "PERSISTENTKEEPALIVE должен быть от 0 до 65535"
    for key in Jc Jmin Jmax S1 S2 S3 S4; do
        is_uint_between "${!key}" 0 65535 || die "$key должен быть от 0 до 65535"
    done
    # Assigned dynamically by load_config and checked in the loop above.
    # shellcheck disable=SC2154
    (( Jmin <= Jmax )) || die "Jmin не должен превышать Jmax"
    for key in H1 H2 H3 H4; do
        value="${!key}"; lo="${value%%-*}"; hi="${value##*-}"
        is_uint_between "$lo" 0 4294967295 && is_uint_between "$hi" 0 4294967295 && (( lo <= hi )) || die "$key: ожидается uint32 или диапазон min-max"
        [[ "$value" == "$lo" || "$value" == "$lo-$hi" ]] || die "$key: некорректный диапазон"
        for other in "${!lows[@]}"; do
            (( hi < lows[other] || lo > highs[other] )) || die "Диапазоны H1–H4 не должны пересекаться"
        done
        lows+=("$lo"); highs+=("$hi")
    done
    [[ "$WG_MTU" == auto ]] || is_uint_between "$WG_MTU" 576 9000 || die "WG_MTU должен быть auto или от 576 до 9000"
    [[ "$STARTUP_HEALTHCHECK" == off || "$STARTUP_HEALTHCHECK" == warn || "$STARTUP_HEALTHCHECK" == strict ]] || die "STARTUP_HEALTHCHECK: ожидается off, warn или strict"
    [[ "$BLOCK_IPV6" == on || "$BLOCK_IPV6" == off ]] || die "BLOCK_IPV6: ожидается on или off"
    is_https_url "$HEALTHCHECK_URL" || die "HEALTHCHECK_URL: ожидается корректный HTTPS URL без userinfo"
    is_uint_between "$PROXY_PARENT_RETRIES" 1 10 || die "PROXY_PARENT_RETRIES должен быть от 1 до 10"
    [[ -z "$PROXY_MAXSEG" ]] || is_uint_between "$PROXY_MAXSEG" 536 8960 || die "PROXY_MAXSEG должен быть от 536 до 8960"
    for item in $IPLIST_URLS; do is_https_url "$item" || die "IPLIST_URLS: ожидаются HTTPS URL"; done
    value="${ALLOWED_IPS//[[:space:]]/}"
    [[ "$value" != ,* && "$value" != *, && "$value" != *,,* ]] || die "Некорректный список ALLOWED_IPS"
    for item in ${ALLOWED_IPS//,/ }; do
        is_ipv4 "$item" || is_ipv4_cidr "$item" || die "ALLOWED_IPS: ожидаются IPv4-адреса или CIDR"
    done
    [[ "$SANDBOX_NETNS_NAME" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ && "$SANDBOX_NETNS_NAME" != . && "$SANDBOX_NETNS_NAME" != .. ]] || die "Недопустимое имя SANDBOX_NETNS_NAME"
    [[ "${SANDBOX_VETH_SUBNET##*/}" == 30 ]] && is_ipv4 "${SANDBOX_VETH_SUBNET%/*}" || die "SANDBOX_VETH_SUBNET: ожидается IPv4 CIDR /30"
    for item in $SANDBOX_HIDE_PATHS; do
        [[ "$item" == /* && "$item" != *..* ]] || die "SANDBOX_HIDE_PATHS: ожидаются абсолютные пути без .."
    done
    [[ "$SANDBOX_NO_PROXY" != *[[:space:]]* ]] || die "SANDBOX_NO_PROXY: без пробелов, через запятую"
    [[ -z "$SANDBOX_EXPECTED_EXIT_IP" ]] || is_ipv4 "$SANDBOX_EXPECTED_EXIT_IP" || die "SANDBOX_EXPECTED_EXIT_IP: ожидается IPv4-адрес"
}
