#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
export AMNEZIA_PROXY_RUNTIME_DIR="$TEST_TMP/runtime"
export AMNEZIA_PROXY_STATE_DIR="$TEST_TMP/state"
export AMNEZIA_PROXY_CACHE_DIR="$TEST_TMP/cache"
export AMNEZIA_PROXY_CONFIG="$TEST_TMP/config"
source "$PROJECT_ROOT/bin/amnezia-proxy"
init_paths
fail() { echo "FAIL: $*" >&2; exit 1; }
for pair in 'true true' 'on off' '0 1'; do
    read -r vpn proxy <<< "$pair"
    cp "$PROJECT_ROOT/tests/fixtures/valid.conf" "$CONFIG_FILE"
    printf '\nVPN_ON=%s\nPROXY_ON=%s\n' "$vpn" "$proxy" >> "$CONFIG_FILE"
    load_config >/dev/null
    expected="$VPN_ON:$PROXY_ON"
    session_write ready
    VPN_ON=0; PROXY_ON=0
    session_load || fail 'snapshot load'
    [[ "$VPN_ON:$PROXY_ON" == "$expected" ]] || fail 'snapshot flags'
    (
        calls="$TEST_TMP/calls"
        : > "$calls"
        rm "$SESSION_FILE"
        check_deps() { :; }
        block_ipv6() { :; }
        prepare_network_targets() { :; }
        ensure_proxy_ports_available() { :; }
        build_allowed_ips() { echo routes >> "$calls"; }
        vpn_wait_connected() { :; }
        start_tunnel() { echo vpn >> "$calls"; }
        start_guard() { echo guard >> "$calls"; }
        start_proxy() { echo proxy >> "$calls"; }
        run_startup_healthcheck() { :; }
        do_start >/dev/null
        [[ "$(grep -c '^vpn$' "$calls" || true)" == "$VPN_ON" ]] || fail 'VPN calls'
        [[ "$(grep -c '^proxy$' "$calls" || true)" == "$PROXY_ON" ]] || fail 'proxy calls'
        [[ "$(grep -c '^guard$' "$calls" || true)" == "$((VPN_ON && PROXY_ON))" ]] || fail 'guard calls'
    )
    rm -f "$SESSION_FILE"
done
printf 'VPN_ON=false\nPROXY_ON=1\nPROXY_STRING=203.0.113.1:3128:user:pass\nVPN_LINK=invalid\n' > "$CONFIG_FILE"
load_config >/dev/null
[[ "$VPN_ON" == 0 ]] || fail 'proxy-only minimal config'
session_write ready
# Runtime diagnostics survives missing user config, without invoking VPN tools.
rm "$CONFIG_FILE"
is_manager_running() { return 0; }
is_proxy_running() { return 0; }
is_proxy_ready() { return 0; }
http_proxy_healthy() { return 0; }
socks_proxy_healthy() { return 0; }
ipv6_block_active() { return 0; }
PROXY_CONNECT_HOST=203.0.113.1
PROXY_HOST=203.0.113.1; PROXY_PORT=3128; PROXY_USER=user; PROXY_PASS=pass
generate_proxy_config
ip() { fail 'proxy-only called ip'; }
awg() { fail 'proxy-only called awg'; }
do_status > "$TEST_TMP/status"
grep -q 'VPN: DISABLED' "$TEST_TMP/status" || fail 'disabled VPN diagnosis'
printf 'version=999\n' > "$SESSION_FILE"
if session_load; then fail 'invalid version accepted'; fi
printf 'VPN_ON=false\nPROXY_ON=false\n' > "$CONFIG_FILE"
if ( LOG_TO_FILE=0 load_config ) >/dev/null 2>&1; then fail 'empty plan accepted'; fi
for value in TRUE yes '' 2; do
    printf 'VPN_ON=%s\nPROXY_ON=true\n' "$value" > "$CONFIG_FILE"
    if ( LOG_TO_FILE=0 load_config ) >/dev/null 2>&1; then fail 'invalid bool accepted'; fi
done
awk '!/^PROXY_STRING=/' "$PROJECT_ROOT/tests/fixtures/valid.conf" > "$CONFIG_FILE"
printf 'VPN_ON=1\nPROXY_ON=0\nPROXY_STRING=\n' >> "$CONFIG_FILE"
load_config >/dev/null
[[ "$PROXY_ON" == 0 ]] || fail 'VPN-only minimal config'
echo 'OK: component modes, conditional validation, startup composition and runtime diagnostics'
