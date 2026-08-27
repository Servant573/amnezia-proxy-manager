#!/bin/bash

build_allowed_ips() {
    local tmp
    tmp=$(mktemp "${ALLOWED_IPS_CACHE}.XXXXXX")

    echo "${PROXY_HOST}/32" >> "$tmp"

    if [[ -n "${IPLIST_URLS:-}" ]]; then
        local url
        for url in $IPLIST_URLS; do
            log INFO "Скачиваю список: $url"
            if curl -fsSL --proto '=https' --max-time 45 --connect-timeout 10 "$url" >> "$tmp"; then
                log OK "Список загружен"
            else
                log WARN "Не удалось скачать: $url"
            fi
        done
    else
        log WARN "IPLIST_URLS пуст — в туннель пойдёт только прокси"
    fi

    ALLOWED_IPS=$(
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$tmp" \
        | sort -u \
        | paste -sd, -
    )

    local count
    count=$(echo "$ALLOWED_IPS" | tr ',' '\n' | grep -c . || true)
    log INFO "AllowedIPs: ${count} префиксов"

    if [[ -z "$ALLOWED_IPS" ]]; then
        rm -f "$tmp"
        die "AllowedIPs пустой — проверь IPLIST_URLS и сеть"
    fi

    echo "$ALLOWED_IPS" | tr ',' '\n' > "$ALLOWED_IPS_CACHE"
    rm -f "$tmp"
}
