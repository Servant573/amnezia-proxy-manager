#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
export AMNEZIA_PROXY_RUNTIME_DIR="$TEST_TMP/runtime"
export AMNEZIA_PROXY_STATE_DIR="$TEST_TMP/state"
export AMNEZIA_PROXY_CACHE_DIR="$TEST_TMP/cache"
export AMNEZIA_PROXY_CONFIG="$TEST_TMP/config"
fixture="$PROJECT_ROOT/tests/fixtures/valid.conf"
cp "$fixture" "$AMNEZIA_PROXY_CONFIG"
fail() { echo "FAIL: $*" >&2; exit 1; }
cli="$PROJECT_ROOT/bin/amnezia-proxy"
"$cli" config validate >/dev/null
[[ ! -e "$AMNEZIA_PROXY_RUNTIME_DIR" && ! -e "$AMNEZIA_PROXY_STATE_DIR" && ! -e "$AMNEZIA_PROXY_CACHE_DIR" ]] || fail 'validate changed filesystem'
# shellcheck source=../bin/amnezia-proxy
source "$cli"
init_paths
config_with() {
    local key="${1%%=*}" value="${1#*=}"
    awk -v key="$key" 'index($0, key "=") != 1' "$fixture" > "$CONFIG_FILE"
    printf '%s=%s\n' "$key" "$value" >> "$CONFIG_FILE"
}
for spec in 'LOCAL_HTTP_PORT=0' 'LOCAL_SOCKS_PORT=65536' 'LOCAL_HTTP_PORT=8080' \
    'LOCAL_HTTP_PORT=08081' 'LOCAL_HTTP_PORT=' 'WG_MTU=99999999999999999999999999' \
    'ENDPOINT=bad host:123' 'ENDPOINT=198.51.100.1:0' 'ENDPOINT=[:::1]:51820' \
    'ADDRESS=203.0.113.7./32' 'ADDRESS=10.0.0.1/33' 'ADDRESS=2001:db8::1/129' \
    'DNS=999.1.1.1' 'PRIVATE_KEY=secret-marker' 'PUBLIC_KEY=replace-me' \
    'Jmin=71' 'S4=-1' 'H1=2' 'H1=10-2' 'H1=4294967296' 'H1=1-1-1' \
    'HEALTHCHECK_URL=https://' 'HEALTHCHECK_URL=http://example.test' \
    'IPLIST_URLS=https://good.test http://bad.test' 'TYPO=ignored' \
    'PROXY_STRING=203.0.113.7.:3128:user:pass' 'PERSISTENTKEEPALIVE=65536' \
    'ADDRESS=10.0.0.2/32,2001:db8::1/64' 'ADDRESS=::1/128' \
    'ENDPOINT=[::ffff:192.0.2.1]:51820' 'BLOCK_IPV6=maybe' \
    'ALLOWED_IPS=192.0.2.1./24' 'ALLOWED_IPS=192.0.2.0/33' \
    'ALLOWED_IPS=2001:db8::/32' 'ALLOWED_IPS=192.0.2.1,,198.51.100.1' \
    'SANDBOX_VETH_SUBNET=10.200.0.1/30' 'SANDBOX_VETH_SUBNET=10.200.0.3/30' \
    'SANDBOX_VETH_SUBNET=255.255.255.255/30'; do
    config_with "$spec"
    if "$cli" config validate > "$TEST_TMP/result" 2>&1; then fail "invalid value accepted: ${spec%%=*}"; fi
    if grep -q secret-marker "$TEST_TMP/result"; then fail 'secret in validation error'; fi
done
for spec in 'ADDRESS=10.0.0.2/32,10.0.0.3/32' 'BLOCK_IPV6=on' \
    'BLOCK_IPV6=off' 'H1=10-20' 'PRESHARED_KEY=' 'ALLOWED_IPS=' \
    'ALLOWED_IPS=192.0.2.1, 198.51.100.0/24' 'ALLOWED_IPS=0.0.0.0/0' \
    'SANDBOX_VETH_SUBNET=10.200.0.0/30' 'SANDBOX_VETH_SUBNET=10.200.0.252/30'; do
    config_with "$spec"
    "$cli" config validate >/dev/null || fail "valid value rejected: $spec"
done
config_with 'LOCAL_HTTP_PORT=8181'
printf 'LOCAL_HTTP_PORT=8182\n' >> "$CONFIG_FILE"
if "$cli" config validate >/dev/null; then fail 'duplicate key accepted'; fi
cp "$fixture" "$CONFIG_FILE"
load_config >/dev/null
I1=old
load_config >/dev/null
[[ -z "${I1:-}" ]] || fail 'old config value leaked into reload'
is_ipv4 '203.0.113.7.' && fail 'trailing IPv4 dot accepted'

# Both local listeners must belong to the recorded process.
printf '123\n' > "$PID_FILE"
ss() { printf '%s\n' 'LISTEN 0 128 127.0.0.1:8081 0.0.0.0:* users:(("3proxy",pid=123,fd=4))' 'LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:(("other",pid=456,fd=4))'; }
if proxy_ports_listening; then fail 'foreign listener accepted'; fi
unset -f ss
rm "$PID_FILE"

# Failed DNS cleanup after interface deletion must remain retryable.
(
    ALLOWED_IPS=203.0.113.10/32
    DNS=1.1.1.1
    generate_wg_config >/dev/null
    printf '%s 42 %s\n' "$WG_INTERFACE" "$(cat /proc/sys/kernel/random/boot_id)" > "$TUNNEL_OWNER_FILE"
    is_tunnel_up() { return 1; }
    run_privileged() { return 1; }
    if stop_tunnel >/dev/null; then fail 'DNS failure reported successful stop'; fi
    [[ -e "$TUNNEL_OWNER_FILE" && -e "$WG_TMP_CONF" ]] || fail 'DNS retry state lost'
    run_privileged() { return 0; }
    stop_tunnel >/dev/null
    [[ ! -e "$TUNNEL_OWNER_FILE" ]] || fail 'retry did not finish cleanup'
)

# Active config wins over edits to the user's ports; no fresh DNS lookup.
ALLOWED_IPS=203.0.113.10/32
PROXY_CONNECT_HOST=203.0.113.10
generate_wg_config >/dev/null
generate_proxy_config
printf '%s 42 %s\n' "$WG_INTERFACE" "$(cat /proc/sys/kernel/random/boot_id)" > "$TUNNEL_OWNER_FILE"
config_with 'LOCAL_HTTP_PORT=8181'
is_manager_running() { return 0; }
is_proxy_running() { return 0; }
is_proxy_ready() { return 0; }
is_tunnel_up() { return 0; }
interface_index() { echo 42; }
getent() { fail 'diagnostics queried DNS'; }
route_for_ipv4() {
    if [[ "$1" == 203.0.113.10 ]]; then echo "$1 dev amn-test"; else echo "$1 dev eth0"; fi
}
DIAG_GUARD_STATUS=0
guard_is_active() { return "$DIAG_GUARD_STATUS"; }
DIAG_IPV6_STATUS=0
ipv6_block_active() { return "$DIAG_IPV6_STATUS"; }
HANDSHAKE=$(date +%s)
run_privileged() {
    case "$*" in
        'awg show amn-test endpoints') printf '%s 198.51.100.99:51820\n' "$PUBLIC_KEY" ;;
        'awg show amn-test latest-handshakes') printf '%s %s\n' "$PUBLIC_KEY" "$HANDSHAKE" ;;
        *) return 1 ;;
    esac
}
curl() {
    [[ "$1" == -q && "$*" == *'--noproxy '* ]] || fail 'curl not isolated'
    [[ "$*" != *8181* ]] || fail 'diagnostics used edited port'
    printf '%s' "${HTTP_CODE:-204}"
}
do_status > "$TEST_TMP/diagnosis"
grep -q 198.51.100.99 "$TEST_TMP/diagnosis" || fail 'actual endpoint not inspected'
DIAG_GUARD_STATUS=2
result=0; do_status >/dev/null || result=$?
[[ "$result" == 2 ]] || fail 'unknown guard reported healthy'
DIAG_GUARD_STATUS=1
result=0; do_status >/dev/null || result=$?
[[ "$result" == 1 ]] || fail 'broken guard reported healthy'
DIAG_GUARD_STATUS=0
DIAG_IPV6_STATUS=1
result=0; do_status >/dev/null || result=$?
[[ "$result" == 1 ]] || fail 'missing IPv6 block reported healthy'
DIAG_IPV6_STATUS=2
result=0; do_status >/dev/null || result=$?
[[ "$result" == 2 ]] || fail 'unknown IPv6 block reported healthy'
DIAG_IPV6_STATUS=0
config_with 'BLOCK_IPV6=off'
result=0; do_status >/dev/null || result=$?
[[ "$result" == 2 ]] || fail 'IPv6 opt-out reported fully protected'
config_with 'LOCAL_HTTP_PORT=8181'
HANDSHAKE=$(($(date +%s) - 300))
result=0; do_status >/dev/null || result=$?
[[ "$result" == 1 ]] || fail 'stale handshake accepted'
HANDSHAKE=$(date +%s)
HTTP_CODE=302
result=0; do_status >/dev/null || result=$?
[[ "$result" == 1 ]] || fail 'redirect accepted'

# Strict startup checks SOCKS even when HTTP works.
if (
    STARTUP_HEALTHCHECK=strict
    http_proxy_healthy() { return 0; }
    socks_proxy_healthy() { return 1; }
    run_startup_healthcheck >/dev/null
); then fail 'strict startup accepted broken SOCKS'; fi

rm "$TUNNEL_OWNER_FILE"
is_manager_running() { return 1; }
is_proxy_running() { return 1; }
is_tunnel_up() { return 1; }
result=0; do_status >/dev/null || result=$?
[[ "$result" == 3 ]] || fail 'stopped system exit code'
CONFIG_FILE="$TEST_TMP/missing"
load_config() { fail 'stop loaded config'; }
do_stop >/dev/null
do_stop >/dev/null
echo 'OK: validation, diagnosis and config-independent stop passed'
