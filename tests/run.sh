#!/bin/bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${PROJECT_ROOT}/bin/amnezia-proxy"
LAUNCHER="${PROJECT_ROOT}/amnezia-proxy-manager"
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

export AMNEZIA_PROXY_RUNTIME_DIR="${TEST_TMP}/runtime"
export AMNEZIA_PROXY_STATE_DIR="${TEST_TMP}/state"
export AMNEZIA_PROXY_CACHE_DIR="${TEST_TMP}/cache"
export AMNEZIA_PROXY_CONFIG="${TEST_TMP}/config"
export NO_COLOR=1

# shellcheck source=../bin/amnezia-proxy
source "$SCRIPT"
init_paths

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message: ожидалось '$expected', получено '$actual'"
}

assert_file_missing() {
    [[ ! -e "$1" ]] || fail "файл не должен существовать: $1"
}

assert_eq "value with spaces" "$(trim '  value with spaces  ')" "trim"
assert_eq "quoted value" "$(strip_quotes '"quoted value"')" "двойные кавычки"
assert_eq "quoted value" "$(strip_quotes "'quoted value'")" "одинарные кавычки"
is_ipv4 "203.0.113.7" || fail "валидный IPv4 отклонён"
is_ipv4 "999.0.0.1" && fail "невалидный IPv4 принят"
is_ipv4_cidr "203.0.113.0/24" || fail "валидный CIDR отклонён"
is_ipv4_cidr "203.0.113.0/42" && fail "невалидная маска CIDR принята"

printf '%s\n' \
    'WG_INTERFACE=amn-test' \
    'PRIVATE_KEY="private"' \
    'ADDRESS=10.0.0.2/32' \
    'PUBLIC_KEY=public' \
    'PRESHARED_KEY=preshared' \
    'ENDPOINT=198.51.100.1:51820' \
    'PROXY_STRING="203.0.113.1:3128:user:pa:ss"' \
    'WG_MTU=1280' \
    'IPLIST_URLS=' > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

load_config >/dev/null
assert_eq "1280" "$WG_MTU" "WG_MTU из конфига"
assert_eq "pa:ss" "$PROXY_PASS" "двоеточие в пароле"
assert_eq "amn-test" "$WG_INTERFACE" "имя интерфейса"

DNS="1.1.1.1"
ALLOWED_IPS="203.0.113.1/32"
generate_wg_config >/dev/null
grep -q '^MTU = 1280$' "$WG_TMP_CONF" || fail "WG_MTU не попал во временный конфиг"
grep -q '^DNS = 1.1.1.1$' "$WG_TMP_CONF" || fail "DNS не попал во временный конфиг"

WG_MTU=auto
generate_wg_config >/dev/null
if grep -q '^MTU = ' "$WG_TMP_CONF"; then
    fail "WG_MTU=auto должен оставить расчёт MTU awg-quick"
fi
WG_MTU=1280

PROXY_CONNECT_HOST=203.0.113.77
PROXY_MAXSEG=1350
threeproxy_version() { echo 0.9.6; }
generate_proxy_config
grep -q '^timeouts 1 5 30 60 180 1800 15 60 15 5$' "$PROXY_CFG" || fail "неполный набор timeout 3proxy"
grep -q '^parent 1000 http 203.0.113.77 ' "$PROXY_CFG" || fail "HTTP parent не закреплён за IPv4"
grep -q '^fakeresolve$' "$PROXY_CFG" || fail "SOCKS DNS не переведён на upstream"
grep -q '^parent 1000 connect+ 203.0.113.77 ' "$PROXY_CFG" || fail "SOCKS не использует CONNECT+ parent"
grep -q '^maxseg 1350$' "$PROXY_CFG" || fail "PROXY_MAXSEG не попал в конфиг"
PROXY_MAXSEG=""
threeproxy_version_at_least 0 9 6 || fail "сравнение версии 3proxy отклонило равную версию"
threeproxy_version_at_least 0 9 7 && fail "сравнение версии 3proxy приняло старую версию"

ss() { printf '%s\n' 'LISTEN 0 128 127.0.0.1:8081 0.0.0.0:*'; }
is_tcp_port_listening 8081 || fail "listening HTTP-порт не обнаружен"
is_tcp_port_listening 8080 && fail "свободный SOCKS-порт принят за занятый"
unset -f ss

MOCK_BIN="${TEST_TMP}/mock-bin"
mkdir -p "$MOCK_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'printf "203.0.113.10 STREAM host\\n203.0.113.11 STREAM host\\n203.0.113.10 STREAM host\\n"' \
    > "${MOCK_BIN}/getent"
chmod 755 "${MOCK_BIN}/getent"
PATH="${MOCK_BIN}:${PATH}"
assert_eq "203.0.113.10 203.0.113.11" "$(resolve_ipv4_host proxy.test)" "резолвинг hostname"

curl() {
    printf '%s\n' '198.51.100.0/24' '999.1.1.1/24' '192.0.2.0/99' ' # comment'
}
PROXY_IPS="203.0.113.10 203.0.113.11"
IPLIST_URLS="https://lists.example.test/ipv4"
build_allowed_ips >/dev/null
[[ ",$ALLOWED_IPS," == *",203.0.113.10/32,"* ]] || fail "IPv4 прокси не добавлен в AllowedIPs"
[[ ",$ALLOWED_IPS," == *",1.1.1.1/32,"* ]] || fail "туннельный DNS не добавлен в AllowedIPs"
[[ ",$ALLOWED_IPS," == *",198.51.100.0/24,"* ]] || fail "валидный CIDR списка потерян"
[[ "$ALLOWED_IPS" != *"999.1.1.1"* ]] || fail "невалидный IPv4 попал в AllowedIPs"
[[ "$ALLOWED_IPS" != *"/99"* ]] || fail "невалидная маска попала в AllowedIPs"
unset -f curl

WG_INTERFACE=amn-test
PROXY_CONNECT_HOST=203.0.113.10
ENDPOINT_IPS="192.0.2.10"
route_for_ipv4() {
    case "$1" in
        192.0.2.10) echo "192.0.2.10 via 192.0.2.1 dev eth0" ;;
        *) echo "$1 dev amn-test" ;;
    esac
}
verify_tunnel_routes >/dev/null
underlay_mtu_for_ipv4() { echo 1500; }
assert_eq "1420" "$(recommended_awg_mtu)" "автоматическая рекомендация MTU"

route_for_ipv4() { echo "$1 dev amn-test"; }
if (verify_tunnel_routes >/dev/null 2>&1); then
    fail "VPN-петля endpoint не обнаружена"
fi

log INFO "plain log" >/dev/null
if LC_ALL=C grep -q $'\033' "$LOG_FILE"; then
    fail "ANSI-последовательность попала в лог-файл"
fi

printf '%s\n' "$$" > "$PID_FILE"
if is_proxy_running; then
    fail "посторонний PID распознан как 3proxy"
fi

CONFIG_FILE="${TEST_TMP}/missing-config"
status_output=""
if status_output=$(do_status 2>&1); then
    fail "status без конфига должен возвращать ошибку"
fi
[[ "$status_output" == *"Конфиг: НЕ НАЙДЕН"* ]] || fail "status не объяснил отсутствие конфига"

assert_eq "amnezia-proxy ${VERSION}" "$(main --version)" "версия CLI"
assert_eq "amnezia-proxy ${VERSION}" "$("$LAUNCHER" --version)" "совместимый launcher"
main --help | grep -q 'diagnose' || fail "в help отсутствует diagnose"

custom_status=""
if custom_status=$(main --config "${TEST_TMP}/explicit-config" status 2>&1); then
    fail "status с отсутствующим --config должен возвращать ошибку"
fi
[[ "$custom_status" == *"${TEST_TMP}/explicit-config"* ]] || fail "--config не переопределил путь"

# Проверяем XDG-пути и автоматический fallback на старый конфиг.
XDG_RESULT=$(env -u AMNEZIA_PROXY_CONFIG \
    -u AMNEZIA_PROXY_RUNTIME_DIR \
    -u AMNEZIA_PROXY_STATE_DIR \
    -u AMNEZIA_PROXY_CACHE_DIR \
    -u XDG_CONFIG_HOME \
    -u XDG_CACHE_HOME \
    -u XDG_STATE_HOME \
    -u XDG_RUNTIME_DIR \
    HOME="${TEST_TMP}/xdg-home" \
    bash -c 'source "$1"; printf "%s|%s|%s|%s" "$CONFIG_FILE" "$STATE_DIR" "$CACHE_DIR" "$RUNTIME_DIR"' \
    _ "$SCRIPT")
assert_eq "${TEST_TMP}/xdg-home/.config/amnezia-proxy-manager/config|${TEST_TMP}/xdg-home/.local/state/amnezia-proxy-manager|${TEST_TMP}/xdg-home/.cache/amnezia-proxy-manager|/tmp/amnezia-proxy-manager-${UID}" \
    "$XDG_RESULT" "XDG-пути по умолчанию"

mkdir -p "${TEST_TMP}/legacy-home"
touch "${TEST_TMP}/legacy-home/.amnezia-proxy.conf"
LEGACY_RESULT=$(env -u AMNEZIA_PROXY_CONFIG \
    -u XDG_CONFIG_HOME \
    HOME="${TEST_TMP}/legacy-home" \
    bash -c 'source "$1"; printf "%s|%s" "$CONFIG_FILE" "$USING_LEGACY_CONFIG"' \
    _ "$SCRIPT")
assert_eq "${TEST_TMP}/legacy-home/.amnezia-proxy.conf|1" "$LEGACY_RESULT" "fallback старого конфига"

# Проверяем, что TERM завершает foreground-цикл, вызывает cleanup и удаляет PID.
LIFECYCLE_RUNTIME="${TEST_TMP}/lifecycle"
AMNEZIA_PROXY_RUNTIME_DIR="$LIFECYCLE_RUNTIME" \
AMNEZIA_PROXY_STATE_DIR="${TEST_TMP}/lifecycle-state" \
AMNEZIA_PROXY_CACHE_DIR="${TEST_TMP}/lifecycle-cache" \
AMNEZIA_PROXY_CONFIG="${TEST_TMP}/unused" \
bash -c '
    set -euo pipefail
    source "$1"
    init_paths
    do_start() { CONFIG_LOADED=1; }
    stop_components() { printf cleanup > "$RUNTIME_DIR/cleaned"; }
    log() { :; }
    run_manager
' _ "$SCRIPT" &
manager_process=$!

for (( attempt=0; attempt<50; attempt++ )); do
    [[ -f "${LIFECYCLE_RUNTIME}/manager.pid" ]] && break
    sleep 0.05
done
[[ -f "${LIFECYCLE_RUNTIME}/manager.pid" ]] || fail "manager.pid не создан"
kill -TERM "$manager_process"
set +e
wait "$manager_process"
manager_status=$?
set -e
assert_eq "143" "$manager_status" "код завершения по TERM"
[[ -f "${LIFECYCLE_RUNTIME}/cleaned" ]] || fail "cleanup не вызван"
assert_file_missing "${LIFECYCLE_RUNTIME}/manager.pid"

echo "OK: все тесты пройдены"
