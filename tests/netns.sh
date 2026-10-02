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
LOG_FILE="$TEST_TMP/manager.log"
sudo() { [[ "$1" != -n ]] || shift; "$@"; }
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
guard_is_active || { nft -j list table inet "$table"; echo 'Valid firewall not recognized'; exit 1; }
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
if guard_is_active; then echo 'Guard for replaced interface accepted'; exit 1; fi
probe
[[ "$(packets)" -gt "$before" ]] || { echo 'Replacement interface not blocked'; exit 1; }
nft flush chain inet "$table" output
if guard_is_active; then echo 'Empty firewall accepted'; exit 1; fi
nft delete table inet "$table"
status=0; guard_is_active || status=$?
[[ "$status" == 1 ]] || { echo 'Deleted table not classified as failure'; exit 1; }
stop_guard
[[ ! -e "$GUARD_FILE" ]] || exit 1
echo 'OK: kernel blocks underlay and replacement interface; permits VPN output'

# Reproduce awg-quick full-tunnel policy routing using dummy interfaces.
WG_TMP_CONF="$TEST_TMP/full.conf"
printf 'AllowedIPs = 0.0.0.0/0\n' > "$WG_TMP_CONF"
ip -4 route add default dev wan-audit
ip -4 route add default dev vpn-audit table 51820
ip -4 rule add priority 100 not fwmark 51820 table 51820
ip -4 rule add priority 99 table main suppress_prefixlength 0
run_privileged() {
    if [[ "$*" == "awg show $WG_INTERFACE fwmark" ]]; then echo 0xca6c; else sudo -n timeout --kill-after=2 10 "$@"; fi
}
route=$(route_for_ipv4 192.0.2.10)
route_uses_interface "$route" vpn-audit || { echo 'Unmarked traffic missed full VPN'; exit 1; }
route=$(route_for_endpoint 192.0.2.10)
route_uses_interface "$route" wan-audit || { echo 'Marked endpoint missed underlay'; exit 1; }
ENDPOINT_IPS=192.0.2.10
verify_tunnel_routes >/dev/null
ip -4 route replace default dev vpn-audit
if (verify_tunnel_routes >/dev/null 2>&1); then echo 'Full-mode endpoint loop accepted'; exit 1; fi
ip -4 rule delete priority 99
ip -4 rule delete priority 100
ip -4 route flush table 51820
ip -4 route delete default dev vpn-audit
echo 'OK: full VPN policy routing and marked endpoint loop checks passed'

# IPv6 has a real route before blocking; failure cannot be attributed to an
# absent AAAA answer or absent IPv6 connectivity. Everything stays in this netns.
ip link set lo up
ip -6 addr add 2001:db8:1::2/64 dev wan-audit nodad
ip -6 route get 2001:db8:1::1 >/dev/null
probe6() {
    python3 -c 'import socket; s=socket.socket(socket.AF_INET6, socket.SOCK_DGRAM); s.sendto(b"audit", ("2001:db8:1::1", 3128))' 2>/dev/null
}
probe6 || { echo 'IPv6 baseline unavailable'; exit 1; }
nft add table ip6 audit_unrelated
BLOCK_IPV6=on
block_ipv6
ipv6_table=$(<"$IPV6_GUARD_FILE")
ipv6_block_active || { nft -n -j list table ip6 "$ipv6_table"; echo 'IPv6 rule not recognized'; exit 1; }
if probe6; then echo 'IPv6 bypassed block'; exit 1; fi
python3 -c '
import socket
with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as server:
    server.bind(("::1", 0)); server.settimeout(1)
    with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as client:
        client.sendto(b"loopback", server.getsockname())
    assert server.recv(100) == b"loopback"
'
BLOCK_IPV6=off
unblock_ipv6  # changing the config must not disable cleanup of an owned rule
probe6 || { echo 'IPv6 was not restored'; exit 1; }
nft list table ip6 audit_unrelated >/dev/null

# A killed installer leaves recoverable protection, not a silently open path.
BLOCK_IPV6=on
(
    block_ipv6 >/dev/null
    kill -KILL "$BASHPID"
) &
installer=$!
result=0; wait "$installer" 2>/dev/null || result=$?
[[ "$result" == 137 ]] || exit 1
ipv6_block_active
if probe6; then echo 'SIGKILL removed IPv6 protection'; exit 1; fi
ipv6_table=$(<"$IPV6_GUARD_FILE")
nft flush chain ip6 "$ipv6_table" output
if ipv6_block_active; then echo 'Empty IPv6 table accepted'; exit 1; fi
unblock_ipv6
probe6
BLOCK_IPV6=off
block_ipv6
[[ ! -e "$IPV6_GUARD_FILE" ]] || exit 1
nft list table ip6 audit_unrelated >/dev/null
echo 'OK: IPv6 REJECT, loopback, SIGKILL recovery, opt-out and unrelated rules verified'
