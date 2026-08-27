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
main --help | grep -q 'restart' || fail "в help отсутствует restart"

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
