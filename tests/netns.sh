#!/bin/bash
# Runs only in a fresh user/network namespace; never changes the host network.
set -euo pipefail
if [[ "${1:-}" == --container ]]; then
    [[ -f /.dockerenv ]] || { echo 'Container mode requires Docker' >&2; exit 1; }
elif [[ "${1:-}" != --inside ]]; then
    exec unshare --user --map-root-user --net bash "$0" --inside
elif [[ "$(readlink /proc/self/ns/net)" == "$(readlink /proc/1/ns/net)" ]]; then
    echo 'Refusing to run in host network namespace' >&2; exit 1;
fi
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
export AMNEZIA_PROXY_RUNTIME_DIR="$TEST_TMP"
source "$PROJECT_ROOT/bin/amnezia-proxy"
sudo() { "$@"; }
WG_INTERFACE=vpn-audit
PROXY_CONNECT_HOST=198.18.0.1
PROXY_PORT=3128
ip link add vpn-audit type dummy
ip link add wan-audit type dummy
ip link set vpn-audit up
ip link set wan-audit up
ip addr add 198.18.0.2/24 dev vpn-audit
ip addr add 198.19.0.2/24 dev wan-audit
start_guard
table=$(<"$GUARD_FILE")
probe() { timeout 1 bash -c 'exec 3<>/dev/tcp/198.18.0.1/3128' 2>/dev/null || true; }
packets() { nft list table inet "$table" | sed -nE 's/.*counter packets ([0-9]+).*/\1/p'; }
probe
[[ "$(packets)" == 0 ]] || { echo 'VPN traffic blocked'; exit 1; }
ip route replace 198.18.0.1/32 dev wan-audit
probe
[[ "$(packets)" -gt 0 ]] || { echo 'Underlay traffic not blocked'; exit 1; }
before=$(packets)
ip link delete vpn-audit
ip link add vpn-audit type dummy
ip link set vpn-audit up
ip addr add 198.18.0.2/24 dev vpn-audit
ip route replace 198.18.0.1/32 dev vpn-audit
probe
[[ "$(packets)" -gt "$before" ]] || { echo 'Replacement interface not blocked'; exit 1; }
stop_guard
[[ ! -e "$GUARD_FILE" ]] || exit 1
echo 'OK: kernel blocks underlay and replacement interface; permits VPN output'
