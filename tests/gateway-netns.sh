#!/bin/bash
# Requires the AmneziaWG kernel module and unprivileged user/network namespaces.
set -euo pipefail
umask 077
if [[ "${1:-}" != --inside ]]; then
    exec unshare --user --map-root-user --net bash "$0" --inside
fi
[[ "$(readlink /proc/self/ns/net)" != "$(readlink /proc/1/ns/net)" ]] || exit 1
project=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
nodes=()
manager=
service=
phone='' gateway='' exit_node='' service_node=''
cleanup() {
    local pid
    for pid in "$manager" "$service" "${nodes[@]}"; do
        if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
    done
    wait 2>/dev/null || true
    rm -rf -- "$work"
}
trap cleanup EXIT

new_node() {
    unshare --net sleep infinity &
    local pid=$! own_ns attempt
    nodes+=("$pid")
    own_ns=$(readlink /proc/self/ns/net)
    for ((attempt=0; attempt<100; attempt++)); do
        if [[ "$(readlink "/proc/$pid/ns/net")" != "$own_ns" ]]; then
            nsenter --net="/proc/$pid/ns/net" ip link set lo up
            printf -v "$1" '%s' "$pid"
            return
        fi
        sleep .02
    done
    return 1
}

at() { local node="$1"; shift; nsenter --net="/proc/$node/ns/net" "$@"; }
pair() {
    local left="$1" left_if="$2" left_ip="$3" right="$4" right_if="$5" right_ip="$6"
    ip link add "$left_if" type veth peer name "$right_if"
    ip link set "$left_if" netns "$left"
    ip link set "$right_if" netns "$right"
    at "$left" ip addr add "$left_ip" dev "$left_if"
    at "$right" ip addr add "$right_ip" dev "$right_if"
    at "$left" ip link set "$left_if" up
    at "$right" ip link set "$right_if" up
}

# The test is already root in a fresh user namespace.
sudo() { if [[ "$1" == -n ]]; then shift; fi; "$@"; }
export -f sudo
export AMNEZIA_PROXY_RUNTIME_DIR="$work/runtime" AMNEZIA_PROXY_STATE_DIR="$work/state"
export AMNEZIA_PROXY_CACHE_DIR="$work/cache" AMNEZIA_PROXY_CONFIG="$work/apm.conf" NO_COLOR=1
new_node phone
new_node gateway
new_node exit_node
new_node service_node
pair "$phone" wifi 100.64.0.1/30 "$gateway" ingress 100.64.0.2/30
pair "$gateway" transit 100.64.1.1/30 "$exit_node" uplink 100.64.1.2/30
pair "$gateway" wan 192.0.2.1/24 "$service_node" from_gateway 192.0.2.2/24
pair "$exit_node" wan 198.51.100.1/24 "$service_node" from_exit 198.51.100.2/24
at "$gateway" ip route add default via 192.0.2.2
at "$exit_node" ip route add default via 198.51.100.2
at "$service_node" ip addr add 203.0.113.10/32 dev lo
at "$service_node" ip addr add 203.0.113.20/32 dev lo
for node in "$gateway" "$exit_node"; do
    at "$node" sysctl -qw net.ipv4.ip_forward=1
    at "$node" sysctl -qw net.ipv4.conf.all.rp_filter=0
    at "$node" sysctl -qw net.ipv4.conf.default.rp_filter=0
done
for who in phone ingress apm exit; do
    awg genkey > "$work/$who.key"
    awg pubkey < "$work/$who.key" > "$work/$who.pub"
done
at "$gateway" ip link add awg-in type amneziawg
at "$gateway" ip addr add 10.10.0.1/24 dev awg-in
at "$gateway" ip -6 addr add fd00:10::1/64 dev awg-in nodad
at "$gateway" awg set awg-in listen-port 51820 private-key "$work/ingress.key" \
    peer "$(< "$work/phone.pub")" allowed-ips 10.10.0.2/32,fd00:10::2/128
at "$gateway" ip link set awg-in up
at "$phone" ip link add vpn type amneziawg
at "$phone" ip addr add 10.10.0.2/24 dev vpn
at "$phone" ip -6 addr add fd00:10::2/64 dev vpn nodad
at "$phone" awg set vpn private-key "$work/phone.key" peer "$(< "$work/ingress.pub")" \
    allowed-ips 0.0.0.0/0,::/0 endpoint 100.64.0.2:51820
at "$phone" ip link set vpn up
at "$phone" ip route add default dev vpn
at "$phone" ip -6 route add default dev vpn
at "$gateway" ip -6 addr add fd00:20::1/64 dev wan nodad
at "$service_node" ip -6 addr add fd00:20::2/64 dev from_gateway nodad
at "$service_node" ip -6 route add fd00:10::/64 via fd00:20::1
at "$gateway" sysctl -qw net.ipv6.conf.all.forwarding=1
at "$exit_node" ip link add awg-vps type amneziawg
at "$exit_node" ip addr add 10.20.0.1/24 dev awg-vps
at "$exit_node" awg set awg-vps listen-port 51821 private-key "$work/exit.key" \
    peer "$(< "$work/apm.pub")" allowed-ips 10.20.0.2/32
at "$exit_node" ip link set awg-vps up
at "$exit_node" nft -f - <<'EOF'
table ip exit_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        iifname "awg-vps" oifname "wan" masquerade
    }
}
EOF
nsenter --net="/proc/$service_node/ns/net" python3 - <<'PY' &
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import BaseRequestHandler, UDPServer
from threading import Thread

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(self.client_address[0].encode())

class DatagramHandler(BaseRequestHandler):
    def handle(self):
        _, sock = self.request
        sock.sendto(self.client_address[0].encode(), self.client_address)

for address in ('203.0.113.10', '203.0.113.20'):
    datagrams = UDPServer((address, 8000), DatagramHandler)
    Thread(target=datagrams.serve_forever, daemon=True).start()
HTTPServer(('0.0.0.0', 8000), Handler).serve_forever()
PY
service=$!

write_config() {
    local vpn_on=off
    if [[ "$1" == tunnel || "$2" == tunnel ]]; then vpn_on=on; fi
    cat > "$AMNEZIA_PROXY_CONFIG" <<EOF
VPN_ON=$vpn_on
PROXY_ON=off
GATEWAY_ON=on
GATEWAY_INGRESS_IF=awg-in
GATEWAY_WAN_IF=wan
GATEWAY_CIDRS=203.0.113.10
GATEWAY_MATCH_ACTION=$1
GATEWAY_DEFAULT_ACTION=$2
WG_INTERFACE=awg-out
PRIVATE_KEY=$(< "$work/apm.key")
PUBLIC_KEY=$(< "$work/exit.pub")
ADDRESS=10.20.0.2/32
ENDPOINT=100.64.1.2:51821
VPN_CONNECT_TIMEOUT=6
EOF
    chmod 600 "$AMNEZIA_PROXY_CONFIG"
}

apm() { at "$gateway" "$project/apm" "$@"; }
start_gateway() {
    local attempt
    nsenter --net="/proc/$gateway/ns/net" "$project/apm" start > "$work/manager.log" 2>&1 &
    manager=$!
    for ((attempt=0; attempt<100; attempt++)); do
        if grep -Fq 'Система готова' "$work/manager.log"; then return 0; fi
        if ! kill -0 "$manager" 2>/dev/null; then break; fi
        sleep .1
    done
    cat "$work/manager.log" >&2
    return 1
}

request() { at "$phone" curl -qfsS --noproxy '*' --max-time 2 "http://203.0.113.$1:8000/"; }
datagram() {
    at "$phone" python3 - "$1" <<'PY'
import socket
import sys

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.settimeout(2)
    s.connect((f'203.0.113.{sys.argv[1]}', 8000))
    s.send(b'probe')
    print(s.recv(1024).decode())
PY
}
expect_exit() {
    local observed
    if ! observed=$(request "$1") || [[ "$observed" != "$2" ]]; then
        echo "203.0.113.$1: ожидался IP $2, получен ${observed:-нет ответа}" >&2
        return 1
    fi
}
blocked() {
    if request "$1" >/dev/null 2>&1; then
        echo "Утечка трафика к 203.0.113.$1" >&2
        return 1
    fi
}

write_config direct tunnel
apm gateway firewall | at "$gateway" nft -f -
blocked 10
start_gateway
snapshot=$(apm status) || { echo "$snapshot" >&2; exit 1; }
grep -F 'Транзит: правила IPv4 загружены' <<< "$snapshot"
expect_exit 10 192.0.2.1
expect_exit 20 198.51.100.1
[[ "$(datagram 10)" == 192.0.2.1 ]]
[[ "$(datagram 20)" == 198.51.100.1 ]]
if at "$phone" ping -6 -q -c 1 -W 1 fd00:20::2 >/dev/null; then echo 'Обнаружен транзит IPv6' >&2; exit 1; fi
at "$gateway" ip link del awg-out
expect_exit 10 192.0.2.1
blocked 20
apm stop
wait "$manager" || true
manager=
blocked 10

write_config tunnel direct
start_gateway
expect_exit 10 198.51.100.1
expect_exit 20 192.0.2.1
at "$gateway" ip -4 rule del pref 11000
blocked 10
expect_exit 20 192.0.2.1
if apm status > "$work/status"; then echo 'Диагностика пропустила удалённое правило маршрутизации' >&2; exit 1; fi
grep -F 'Маршрут шлюза: FAIL' "$work/status"
apm stop
wait "$manager" || true
manager=

write_config block tunnel
start_gateway
blocked 10
expect_exit 20 198.51.100.1
kill -KILL "$manager"
wait "$manager" 2>/dev/null || true
manager=
at "$gateway" ip link del awg-out
blocked 20
apm stop

write_config tunnel block
start_gateway
expect_exit 10 198.51.100.1
blocked 20
apm stop
wait "$manager" || true
manager=
blocked 10

write_config direct block
start_gateway
expect_exit 10 192.0.2.1
blocked 20
apm status | grep -F 'Транзит: правила IPv4 загружены'
apm stop
wait "$manager" || true
manager=

printf '\nGATEWAY_CIDR_URLS=https://lists.example.test/networks\n' >> "$AMNEZIA_PROXY_CONFIG"
curl() { printf '203.0.113.0/24\nmalformed\n'; }
export -f curl
if at "$gateway" timeout 5 "$project/apm" start > "$work/invalid-list.log" 2>&1; then
    echo 'Шлюз принял список с невалидным префиксом' >&2
    exit 1
fi
grep -F 'содержит невалидный IPv4/CIDR' "$work/invalid-list.log"
blocked 10
echo 'OK: two AWG tunnels, TCP/UDP exit IPs, IPv6, link/rule loss, SIGKILL, stop and invalid CIDR source'
