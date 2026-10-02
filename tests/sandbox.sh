#!/bin/bash
# Проверки sandbox. Forwarder-relay работает без прав. bwrap-маскировка требует
# user/mount namespaces (есть на хосте, нет в minimal-cap Docker), а путь
# netns create/verify/destroy — CAP_SYS_ADMIN (отдельный привилегированный
# прогон). Каждая секция самоограничивается и не падает при отсутствии прав.
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

# --- forwarder: raw TCP relay в обе стороны (без прав) ---
python3 - <<'PY' &
import socket, threading
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 19080))
s.listen(5)
while True:
    c, _ = s.accept()
    def handle(c):
        data = c.recv(4096)
        c.sendall(b"echo:" + data)
        c.close()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
server_pid=$!
sleep 0.2
python3 "$PROJECT_ROOT/lib/sandbox_forwarder.py" '127.0.0.1:19081=127.0.0.1:19080' &
forwarder_pid=$!
sleep 0.3
got=$(python3 -c 'import socket; s=socket.socket(); s.connect(("127.0.0.1",19081)); s.sendall(b"hi"); print(s.recv(100).decode())')
[[ "$got" == "echo:hi" ]] || fail "forwarder relay: получено '$got'"
kill "$forwarder_pid" "$server_pid" 2>/dev/null || true

# --- bwrap: скрыты секреты, resolv.conf и /run/netns недоступны ---
mkdir -p "$TEST_TMP/home"
export HOME="$TEST_TMP/home"
secret_dir="$HOME/.ssh"; mkdir -p "$secret_dir"; echo KEY > "$secret_dir/id_rsa"
secret_file="$HOME/.token"; echo SECRET > "$secret_file"
CONFIG_FILE="$HOME/config"; echo 'PRIVATE_KEY=real' > "$CONFIG_FILE"
LEGACY_CONFIG_FILE="$HOME/legacy"; echo legacy > "$LEGACY_CONFIG_FILE"
SANDBOX_HIDE_PATHS="$secret_dir $secret_file"
SANDBOX_HOST_IP=10.200.0.1; SANDBOX_HTTP_PORT=8081; SANDBOX_SOCKS_PORT=8080
if bwrap --dev /dev --tmpfs /tmp --ro-bind /bin /bin --ro-bind /usr /usr \
    --ro-bind /lib /lib --ro-bind /lib64 /lib64 -- /bin/true 2>/dev/null; then
    sandbox_build_bwrap
    out=$(bwrap "${BWRAP_ARGS[@]}" -- bash -c '
      printf "%s|%s|%s|%s" \
        "$(cat '"$secret_file"' 2>/dev/null)" \
        "$(ls -A '"$secret_dir"' | wc -l)" \
        "$(cat /etc/resolv.conf 2>/dev/null)" \
        "$(test -e /run/netns && echo LEAK || echo none)"
    ')
    [[ "$out" == "|0|nameserver 127.0.0.1|none" ]] || fail "bwrap masking: $out"
else
    echo "(bwrap недоступен без прав на namespaces — секция пропущена)"
fi

# --- netns create/verify/destroy (нужен root и рабочий ip netns add) ---
sudo() { [[ "$1" != -n ]] || shift; "$@"; }
run_privileged() { [[ "$1" != -n ]] || shift; "$@"; }
if ip netns add apm-probe 2>/dev/null; then
    ip netns del apm-probe
    SANDBOX_NETNS_NAME=apm-test
    SANDBOX_VETH_SUBNET=10.223.0.0/30
    SANDBOX_HOST_IF=apm0; SANDBOX_NS_IF=apm1
    sandbox_netns_create
    [[ "$(ip netns exec apm-test ip -o link show | wc -l)" == 2 ]] || fail "netns: не 2 интерфейса"
    ip netns exec apm-test ip route show | grep -q '^default' && fail "netns: есть default-route"
    # Чужой живой процесс не должен удаляться.
    sleep 30 &
    other=$!
    other_id=$(process_identity "$other")
    printf '%s %s %s %s\n%s\n%s\n' \
        apm-test apm0 10.223.0.1 "$(cat /proc/sys/kernel/random/boot_id)" "$other" "$other_id" > "$SANDBOX_FILE"
    if sandbox_netns_destroy; then fail "netns: удалён при живом чужом процессе"; fi
    kill "$other" 2>/dev/null || true
    sandbox_netns_destroy
    ip netns list | grep -q apm-test && fail "netns: не удалён"
    echo "OK: sandbox isolation tests passed (forwarder, bwrap, netns)"
else
    echo "OK: sandbox isolation tests passed (netns пропущен — ip netns add недоступен)"
fi
