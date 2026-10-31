#!/bin/bash

VPN_ON=1
PROXY_ON=1
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

# Расшифровывает VPN_LINK и заполняет поля туннеля. Вызывается до применения
# defaults, чтобы ссылка полностью переопределяла ручные значения, а пропущенные
# ею параметры получили defaults ниже по коду.
apply_vpn_link() {
    [[ -n "${VPN_LINK:-}" ]] || return 0
    command -v python3 >/dev/null 2>&1 || die "python3 не найден; нужен для декодирования VPN_LINK"
    local out
    if ! out=$(printf '%s' "$VPN_LINK" | python3 "$PROJECT_ROOT/lib/vpn_link.py"); then
        die "Не удалось декодировать VPN_LINK"
    fi

    # Роутинг (ALLOWED_IPS/IPLIST_URLS) и тюнинг (DNS, WG_MTU,
    # PERSISTENTKEEPALIVE) остаются пользовательскими и не берутся из ссылки:
    # ссылка задаёт только «личность» туннеля и обфускацию.
    PRIVATE_KEY=""; PUBLIC_KEY=""; PRESHARED_KEY=""; ADDRESS=""; ENDPOINT=""
    Jc=""; Jmin=""; Jmax=""; S1=""; S2=""; S3=""; S4=""
    H1=""; H2=""; H3=""; H4=""; I1=""; I2=""; I3=""; I4=""; I5=""

    local line key value
    while IFS= read -r line; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            PRIVATE_KEY|PUBLIC_KEY|PRESHARED_KEY|ADDRESS|ENDPOINT|Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5)
                printf -v "$key" '%s' "$value" ;;
        esac
    done <<< "$out"
    log INFO "Туннель настроен из VPN_LINK"
}

CONFIG_KEYS='VPN_CONNECT_TIMEOUT VPN_ON PROXY_ON WG_INTERFACE PRIVATE_KEY ADDRESS DNS PUBLIC_KEY ENDPOINT PERSISTENTKEEPALIVE
Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 PRESHARED_KEY
PROXY_STRING LOCAL_HTTP_PORT LOCAL_SOCKS_PORT ALLOWED_IPS IPLIST_URLS WG_MTU
HEALTHCHECK_URL STARTUP_HEALTHCHECK PROXY_MAXSEG PROXY_PARENT_RETRIES BLOCK_IPV6
SANDBOX_NETNS_NAME SANDBOX_VETH_SUBNET SANDBOX_HIDE_PATHS SANDBOX_NO_PROXY SANDBOX_EXPECTED_EXIT_IP
VPN_LINK'

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Конфиг не найден: $CONFIG_FILE"

    local cfg_perms
    cfg_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$cfg_perms" && "$cfg_perms" != "600" && "$cfg_perms" != "400" ]]; then
        log WARN "Конфиг $CONFIG_FILE имеет права $cfg_perms — рекомендуется chmod 600"
    fi

    local key value line number=0 known empty_keys=""
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
                DNS|PRESHARED_KEY|ALLOWED_IPS|IPLIST_URLS|PROXY_MAXSEG|I1|I2|I3|I4|I5|SANDBOX_HIDE_PATHS|SANDBOX_NO_PROXY|SANDBOX_EXPECTED_EXIT_IP|PRIVATE_KEY|ADDRESS|PUBLIC_KEY|ENDPOINT|VPN_LINK) ;;
                *) empty_keys+=" $key" ;;
            esac
        fi
        printf -v "$key" '%s' "$value"
    done < "$CONFIG_FILE"

    VPN_ON=$(normalize_switch "${VPN_ON:-true}") || die "VPN_ON: ожидается true/false, on/off или 1/0"
    PROXY_ON=$(normalize_switch "${PROXY_ON:-true}") || die "PROXY_ON: ожидается true/false, on/off или 1/0"
    for key in $empty_keys; do
        case "$key" in
            VPN_ON|PROXY_ON) die "$key не должен быть пустым" ;;
            PROXY_STRING|LOCAL_HTTP_PORT|LOCAL_SOCKS_PORT|PROXY_PARENT_RETRIES)
                (( ! PROXY_ON )) || die "$key не должен быть пустым" ;;
            WG_INTERFACE|PERSISTENTKEEPALIVE|Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|WG_MTU|VPN_CONNECT_TIMEOUT)
                (( ! VPN_ON )) || die "$key не должен быть пустым" ;;
            *) die "$key не должен быть пустым" ;;
        esac
    done
    if (( VPN_ON )); then apply_vpn_link; fi

    : "${WG_INTERFACE:=}" "${PRIVATE_KEY:=}" "${ADDRESS:=}"
    : "${PUBLIC_KEY:=}" "${ENDPOINT:=}" "${PROXY_STRING:=}"
    : "${IPLIST_URLS:=}"
    : "${ALLOWED_IPS:=}"
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
    : "${VPN_CONNECT_TIMEOUT:=30}"
    : "${HEALTHCHECK_URL:=https://api.ipify.org}"
    : "${STARTUP_HEALTHCHECK:=warn}"
    : "${PROXY_MAXSEG:=}"
    : "${PROXY_PARENT_RETRIES:=2}"
    : "${BLOCK_IPV6:=on}"
    : "${SANDBOX_NETNS_NAME:=apm-sandbox}"
    : "${SANDBOX_VETH_SUBNET:=10.200.0.0/30}"
    : "${SANDBOX_HIDE_PATHS:=}"
    : "${SANDBOX_NO_PROXY:=}"
    : "${SANDBOX_EXPECTED_EXIT_IP:=}"
    : "${VPN_LINK:=}"

    validate_config_values

    WG_TMP_CONF="${RUNTIME_DIR}/${WG_INTERFACE}.conf"
    CONFIG_LOADED=1
    log INFO "Конфиг загружен. VPN=$VPN_ON; proxy=$PROXY_ON"
}

normalize_switch() {
    case "$1" in
        true|on|1) echo 1 ;;
        false|off|0) echo 0 ;;
        *) return 1 ;;
    esac
}
