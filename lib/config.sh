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

CONFIG_KEYS='WG_INTERFACE PRIVATE_KEY ADDRESS DNS PUBLIC_KEY ENDPOINT PERSISTENTKEEPALIVE
Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 PRESHARED_KEY
PROXY_STRING LOCAL_HTTP_PORT LOCAL_SOCKS_PORT IPLIST_URLS WG_MTU
HEALTHCHECK_URL STARTUP_HEALTHCHECK PROXY_MAXSEG PROXY_PARENT_RETRIES BLOCK_IPV6'

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

    local key value line number=0 known
    local -A seen=()
    CONFIG_LOADED=0
    for key in $CONFIG_KEYS; do unset "$key"; done
    PROXY_IPS=""; PROXY_CONNECT_HOST=""; ENDPOINT_IPS=""; ENDPOINT_CONNECT_HOST=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        number=$((number + 1))
        line=$(trim "$line")
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || die "Конфиг, строка $number: ожидается KEY=value"
        key=$(trim "${line%%=*}")
        [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || die "Конфиг, строка $number: некорректное имя параметра"
        known=0
        for value in $CONFIG_KEYS; do [[ "$key" != "$value" ]] || known=1; done
        [[ "$known" == 1 ]] || die "Конфиг, строка $number: неизвестный параметр $key"
        [[ -z "${seen[$key]:-}" ]] || die "Конфиг, строка $number: повтор параметра $key"
        seen[$key]=1
        value=$(trim "${line#*=}")
        if [[ "$value" == \"* || "$value" == \'* ]]; then
            [[ ${#value} -ge 2 && "${value:0:1}" == "${value: -1}" ]] || die "Конфиг, строка $number: незакрытая кавычка"
        fi
        value=$(strip_quotes "$value")
        [[ "$value" != *[[:cntrl:]]* ]] || die "Конфиг, строка $number: управляющие символы запрещены"
        if [[ -z "$value" ]]; then
            case "$key" in
                DNS|PRESHARED_KEY|IPLIST_URLS|PROXY_MAXSEG|I1|I2|I3|I4|I5) ;;
                *) die "Конфиг, строка $number: $key не должен быть пустым" ;;
            esac
        fi
        printf -v "$key" '%s' "$value"
    done < "$CONFIG_FILE"

    : "${WG_INTERFACE:=}" "${PRIVATE_KEY:=}" "${ADDRESS:=}"
    : "${PUBLIC_KEY:=}" "${ENDPOINT:=}" "${PROXY_STRING:=}"
    : "${IPLIST_URLS:=}"
    : "${PRESHARED_KEY:=}"
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
    : "${WG_MTU:=auto}"
    : "${HEALTHCHECK_URL:=https://api.ipify.org}"
    : "${STARTUP_HEALTHCHECK:=warn}"
    : "${PROXY_MAXSEG:=}"
    : "${PROXY_PARENT_RETRIES:=2}"
    : "${BLOCK_IPV6:=on}"

    validate_config_values

    WG_TMP_CONF="${RUNTIME_DIR}/${WG_INTERFACE}.conf"
    CONFIG_LOADED=1
    log INFO "Конфиг загружен. Прокси: $PROXY_HOST:$PROXY_PORT"
}
