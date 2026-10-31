#!/bin/bash
# Runtime-only inspection and runner checks: no sudo, mounts or network changes.
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
export AMNEZIA_PROXY_RUNTIME_DIR="$TEST_TMP/runtime"
export AMNEZIA_PROXY_STATE_DIR="$TEST_TMP/state"
export AMNEZIA_PROXY_CACHE_DIR="$TEST_TMP/cache"
export AMNEZIA_PROXY_CONFIG="$TEST_TMP/config"
cp "$PROJECT_ROOT/tests/fixtures/valid.conf" "$AMNEZIA_PROXY_CONFIG"
source "$PROJECT_ROOT/bin/amnezia-proxy"
init_paths
load_config >/dev/null
fail() { echo "FAIL: $*" >&2; exit 1; }
PROXY_CONNECT_HOST=203.0.113.77
PROXY_PORT=4321
LOCAL_HTTP_PORT=8181
LOCAL_SOCKS_PORT=8180
ENDPOINT_CONNECT_HOST=198.51.100.1
ALLOWED_IPS=0.0.0.0/0
generate_wg_config >/dev/null
generate_proxy_config
session_write ready
printf '%s 42 %s\n' "$WG_INTERFACE" "$(cat /proc/sys/kernel/random/boot_id)" > "$TUNNEL_OWNER_FILE"
printf 'apm_%s_01234567890123456789012345678901\n' "$UID" > "$GUARD_FILE"
printf 'apm6_%s_01234567890123456789012345678901\n' "$UID" > "$IPV6_GUARD_FILE"
rm "$CONFIG_FILE"
is_manager_running() { return 0; }
is_proxy_running() { return 0; }
is_proxy_ready() { return 0; }
is_tunnel_up() { return 0; }
interface_index() { echo 42; }
run_privileged() { return 1; }
http_proxy_healthy() { return 0; }
socks_proxy_healthy() { return 0; }
route_for_ipv4() { echo "$1 dev $WG_INTERFACE"; }
effective_tunnel_mtu() { echo 1420; }
unset PROXY_CONNECT_HOST PROXY_PORT ENDPOINT_IPS PUBLIC_KEY
status=0
do_diagnose > "$TEST_TMP/diagnosis" 2> "$TEST_TMP/stderr" || status=$?
[[ "$status" == 2 ]] || fail "missing privilege must be UNKNOWN, got $status"
[[ ! -s "$TEST_TMP/stderr" ]] || fail "diagnosis emitted shell error"
grep -q 'MTU: оценка underlay UNKNOWN' "$TEST_TMP/diagnosis" || fail 'missing MTU explanation'
grep -q 'HTTP proxy: OK' "$TEST_TMP/diagnosis" || fail 'diagnosis stopped before proxy checks'
[[ "$PROXY_CONNECT_HOST:$PROXY_PORT" == 203.0.113.77:4321 ]] || fail 'active upstream lost'
unset ENDPOINT_IPS
if recommended_awg_mtu; then fail 'missing endpoint accepted for MTU estimate'; fi

# Run from a fresh snapshot: guard MUST see fields restored from 3proxy.cfg.
check_sandbox_deps() { :; }
guard_is_active() {
    [[ "${PROXY_CONNECT_HOST:-}:${PROXY_PORT:-}" == 203.0.113.77:4321 &&
       "$SANDBOX_HTTP_PORT:$SANDBOX_SOCKS_PORT" == 8181:8180 ]] || return 1
    return "${MOCK_GUARD_STATUS:-0}"
}
sandbox_netns_create() { sandbox_addrs; touch "$TEST_TMP/created"; }
sandbox_start_forwarder() { :; }
sandbox_verify() { :; }
sandbox_build_bwrap() { :; }
sandbox_run_agent() { :; }
(
    unset PROXY_CONNECT_HOST PROXY_PORT
    do_run /bin/true
)
[[ -e "$TEST_TMP/created" ]] || fail 'runner did not pass guard'
rm "$TEST_TMP/created"
for code in 1 2; do
    if ( MOCK_GUARD_STATUS="$code"; do_run /bin/true ) > "$TEST_TMP/guard-$code" 2>&1; then
        fail 'runner accepted missing/unverifiable guard'
    fi
    [[ ! -e "$TEST_TMP/created" ]] || fail 'namespace created before guard confirmation'
done
grep -q 'проверка недоступна' "$TEST_TMP/guard-2" || fail 'unknown guard reported as broken'
grep -q 'правило отсутствует' "$TEST_TMP/guard-1" || fail 'broken guard not explained'
# Actual dependency helper: denied sudo must fail before lifecycle starts.
if bash -c '
    source "$1/bin/amnezia-proxy"
    command() { [[ "$1" != -v ]] || return 0; builtin command "$@"; }
    sudo() { [[ "$*" == -v ]] || exit 99; return 1; }
    check_sandbox_deps
' _ "$PROJECT_ROOT" > "$TEST_TMP/auth" 2>&1; then fail 'sudo denial ignored'; fi
grep -q 'sudo-доступ' "$TEST_TMP/auth" || fail 'sudo denial not explained'
echo 'OK: missing privileges preserve diagnostics; runner restores upstream before mandatory guard and explains failures'
