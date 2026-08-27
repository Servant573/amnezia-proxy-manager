#!/bin/bash

CONFIG_LOADED=0
WG_TMP_CONF=""

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

strip_quotes() {
    local s="$1"
    if [[ ( "$s" == \"*\" && "$s" == *\" && ${#s} -ge 2 ) || \
          ( "$s" == \'*\' && "$s" == *\' && ${#s} -ge 2 ) ]]; then
        s="${s:1:-1}"
    fi
    printf '%s' "$s"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Конфиг не найден: $CONFIG_FILE"

    if [[ "$USING_LEGACY_CONFIG" == "1" ]]; then
        log WARN "Используется старый путь $LEGACY_CONFIG_FILE; новый путь: $DEFAULT_CONFIG_FILE"
    fi

    local cfg_perms
    cfg_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$cfg_perms" && "$cfg_perms" != "600" && "$cfg_perms" != "400" ]]; then
        log WARN "Конфиг $CONFIG_FILE имеет права $cfg_perms — рекомендуется chmod 600"
    fi

    local key value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(trim "$key")
        value=$(strip_quotes "$(trim "$value")")

        case "$key" in
            WG_INTERFACE|PRIVATE_KEY|ADDRESS|DNS|PUBLIC_KEY|ENDPOINT|PERSISTENTKEEPALIVE|\
            Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5|PRESHARED_KEY|\
            PROXY_STRING|LOCAL_HTTP_PORT|LOCAL_SOCKS_PORT|IPLIST_URLS|WG_MTU)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$CONFIG_FILE"

    : "${WG_INTERFACE:?WG_INTERFACE не задан}"
    : "${PRIVATE_KEY:?PRIVATE_KEY не задан}"
    : "${ADDRESS:?ADDRESS не задан}"
    : "${PUBLIC_KEY:?PUBLIC_KEY не задан}"
    : "${ENDPOINT:?ENDPOINT не задан}"
    : "${PROXY_STRING:?PROXY_STRING не задан}"
    : "${IPLIST_URLS:=}"
    : "${PRESHARED_KEY:?PRESHARED_KEY не задан}"
    : "${LOCAL_HTTP_PORT:=8081}"
    : "${LOCAL_SOCKS_PORT:=8080}"
    : "${PERSISTENTKEEPALIVE:=25}"
    : "${DNS:=}"
    : "${Jc:=4}"
    : "${Jmin:=40}"
    : "${Jmax:=70}"
    : "${S1:=0}"
    : "${S2:=0}"
    : "${S3:=0}"
    : "${S4:=0}"
    : "${H1:=1}"
    : "${H2:=2}"
    : "${H3:=3}"
    : "${H4:=4}"
    : "${WG_MTU:=1340}"

    IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$PROXY_STRING"
    [[ -n "$PROXY_HOST" && -n "$PROXY_PORT" && -n "$PROXY_USER" && -n "$PROXY_PASS" ]] \
        || die "Не удалось распарсить PROXY_STRING. Ожидается host:port:user:pass"

    WG_TMP_CONF="${RUNTIME_DIR}/${WG_INTERFACE}.conf"
    CONFIG_LOADED=1
    log INFO "Конфиг загружен. Прокси: $PROXY_HOST:$PROXY_PORT"
}
