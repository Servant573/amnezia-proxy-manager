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
cp "$PROJECT_ROOT/tests/fixtures/valid.conf" "$CONFIG_FILE"
printf '\nALLOWED_IPS="192.0.2.7, 198.51.100.0/24"\n' >> "$CONFIG_FILE"
load_config >/dev/null
[[ "$ALLOWED_IPS" == '192.0.2.7, 198.51.100.0/24' ]] || fail 'manual config lost'
PROXY_IPS=203.0.113.10
DNS=1.1.1.1
IPLIST_URLS=''
build_allowed_ips >/dev/null
[[ "$ALLOWED_IPS" == '1.1.1.1/32,192.0.2.7/32,198.51.100.0/24,203.0.113.10/32' ]] || fail 'manual list or infrastructure routes lost'

ALLOWED_IPS=''; IPLIST_URLS=''
curl() { fail 'full mode downloaded a list'; }
build_allowed_ips >/dev/null
[[ "$ALLOWED_IPS" == 0.0.0.0/0 ]] || fail 'empty sources did not select full VPN'

curl() {
    case "${*: -1}" in
        https://lists.test/one) printf '192.0.2.7\r\n198.51.100.0/24 # comment\n999.1.1.1/24\n' ;;
        https://lists.test/two) printf '198.51.100.0/24, 198.18.0.0/15' ;;
        https://lists.test/empty) printf '# no routes\ninvalid\n' ;;
        *) return 22 ;;
    esac
}
ALLOWED_IPS='192.0.2.7 10.20.0.0/16'
IPLIST_URLS='https://lists.test/one https://lists.test/two'
build_allowed_ips >/dev/null
[[ "$ALLOWED_IPS" == '1.1.1.1/32,10.20.0.0/16,192.0.2.7/32,198.18.0.0/15,198.51.100.0/24,203.0.113.10/32' ]] || fail 'URL union/deduplication broken'
ALLOWED_IPS=''; IPLIST_URLS=https://lists.test/two
build_allowed_ips >/dev/null
[[ "$ALLOWED_IPS" == '1.1.1.1/32,198.18.0.0/15,198.51.100.0/24,203.0.113.10/32' ]] || fail 'URL-only routes lost'
cp "$ALLOWED_IPS_CACHE" "$TEST_TMP/previous"
for url in https://lists.test/empty https://lists.test/failure 'https://lists.test/two https://lists.test/failure'; do
    if ( ALLOWED_IPS=''; IPLIST_URLS="$url"; build_allowed_ips >/dev/null 2>&1 ); then fail 'bad URL silently widened/degraded routes'; fi
    cmp "$ALLOWED_IPS_CACHE" "$TEST_TMP/previous" || fail 'failed fetch overwrote cache'
done
ALLOWED_IPS=0.0.0.0/0; IPLIST_URLS=''
build_allowed_ips >/dev/null
generate_wg_config >/dev/null
grep -q '^AllowedIPs = 0.0.0.0/0$' "$WG_TMP_CONF" || fail 'WG config lost default'
run_privileged() { [[ "$*" == "awg show $WG_INTERFACE fwmark" ]] || return 1; echo 0xca6c; }
ip() {
    [[ "$*" == '-4 route get 198.51.100.1 mark 0xca6c' ]] || fail 'endpoint lookup missing fwmark'
    echo '198.51.100.1 dev underlay mark 0xca6c'
}
route_for_endpoint 198.51.100.1 >/dev/null
for expected_mark in off 0 invalid; do
    run_privileged() { echo "$expected_mark"; }
    if route_for_endpoint 198.51.100.1 >/dev/null; then fail 'invalid fwmark accepted'; fi
done
run_privileged() { return 1; }
if route_for_endpoint 198.51.100.1 >/dev/null; then fail 'missing fwmark ignored'; fi
echo 'OK: manual/URL/full routes, failed fetch preservation and marked endpoint lookup passed'
