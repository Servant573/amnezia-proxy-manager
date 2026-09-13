#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
export AMNEZIA_PROXY_RUNTIME_DIR="$TEST_TMP/runtime"
export AMNEZIA_PROXY_STATE_DIR="$TEST_TMP/state"
export AMNEZIA_PROXY_CACHE_DIR="$TEST_TMP/cache"
export AMNEZIA_PROXY_CONFIG="$PROJECT_ROOT/tests/fixtures/valid.conf"
source "$PROJECT_ROOT/bin/amnezia-proxy"
init_paths
load_config >/dev/null
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$BLOCK_IPV6" == on ]] || fail 'IPv6 block is not the default'

ENDPOINT=dual.test:51820
getent() { printf '%s\n' '198.51.100.9 STREAM dual.test' '198.51.100.10 STREAM dual.test'; }
prepare_network_targets >/dev/null
ALLOWED_IPS=203.0.113.10/32
generate_wg_config >/dev/null
grep -q '^Endpoint = 198.51.100.9:51820$' "$WG_TMP_CONF" || fail 'endpoint DNS not pinned'
[[ "$ENDPOINT_IPS" == 198.51.100.9 ]] || fail 'route check targets differ from actual endpoint'
getent() { return 0; }
if (prepare_network_targets >/dev/null 2>&1); then fail 'AAAA-only/failed DNS accepted'; fi
ENDPOINT='[2001:db8::1]:51820'
if (prepare_network_targets >/dev/null 2>&1); then fail 'IPv6 endpoint accepted'; fi
ENDPOINT_IPS=''
if (verify_tunnel_routes >/dev/null 2>&1); then fail 'empty endpoint skipped route verification'; fi

# Failure installing IPv6 protection must roll back and never proceed to DNS.
export IPV6_TEST_ROOT="$TEST_TMP"
if bash -c '
    source "$1"
    init_paths
    check_deps() { :; }
    sudo() { return 1; }
    run_privileged() { return 0; }
    prepare_network_targets() { touch "$IPV6_TEST_ROOT/dns-called"; }
    run_manager
' _ "$PROJECT_ROOT/bin/amnezia-proxy" >/dev/null 2>&1; then fail 'failed IPv6 protection accepted'; fi
[[ ! -e "$TEST_TMP/dns-called" ]] || fail 'DNS ran before mandatory IPv6 protection'
[[ ! -e "$IPV6_GUARD_FILE" ]] || fail 'failed atomic install not rolled back'

# Cleanup retains IPv6 protection if proxy shutdown failed, and removes it last.
CONFIG_LOADED=1; PROXY_OWNED=1; TUNNEL_OWNED=1; GUARD_OWNED=1; IPV6_OWNED=1
stop_proxy() { return 1; }
unblock_ipv6() { touch "$TEST_TMP/unblocked"; }
cleanup >/dev/null
[[ ! -e "$TEST_TMP/unblocked" ]] || fail 'IPv6 unblocked before proxy stopped'
CLEANUP_DONE=0
stop_proxy() { echo proxy >> "$TEST_TMP/order"; }
stop_tunnel() { echo tunnel >> "$TEST_TMP/order"; }
stop_guard() { echo guard >> "$TEST_TMP/order"; }
unblock_ipv6() { echo ipv6 >> "$TEST_TMP/order"; }
cleanup >/dev/null
[[ "$(<"$TEST_TMP/order")" == $'proxy\ntunnel\nguard\nipv6' ]] || fail 'unsafe unblock order'
echo 'OK: IPv4-only endpoint, pinned DNS, IPv6 install failure and cleanup order verified'
