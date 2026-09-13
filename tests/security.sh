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

# Refuse unsafe directories without changing their permissions/targets.
mkdir "$TEST_TMP/unsafe"
chmod 777 "$TEST_TMP/unsafe"
if (secure_directory "$TEST_TMP/unsafe" 2>/dev/null); then fail 'writable directory accepted'; fi
[[ "$(stat -c %a "$TEST_TMP/unsafe")" == 777 ]] || fail 'permissions silently changed'
ln -s "$TEST_TMP/runtime" "$TEST_TMP/link"
if (secure_directory "$TEST_TMP/link" 2>/dev/null); then fail 'symlink accepted'; fi
printf sentinel > "$TEST_TMP/target"
ln -s "$TEST_TMP/target" "$PROXY_CFG"
if (init_paths 2>/dev/null); then fail 'runtime symlink accepted'; fi
[[ "$(<"$TEST_TMP/target")" == sentinel ]] || fail 'symlink target changed'
rm "$PROXY_CFG"
ln "$TEST_TMP/target" "$PROXY_CFG"
if (init_paths 2>/dev/null); then fail 'runtime hardlink accepted'; fi
rm "$PROXY_CFG"

# Never invoke privileged deletion for an unowned interface or early failure.
sudo() { printf '%s\n' "$*" >> "$TEST_TMP/privileged"; return 1; }
is_tunnel_up() { return 0; }
if (start_tunnel >/dev/null 2>&1); then fail 'existing interface accepted'; fi
stop_tunnel
cleanup >/dev/null
[[ ! -e "$TEST_TMP/privileged" ]] || fail 'unowned resources touched'
CLEANUP_DONE=0

# A replacement interface with the same name has a different index.
ALLOWED_IPS=203.0.113.10/32
generate_wg_config >/dev/null
printf '%s 42 %s\n' "$WG_INTERFACE" "$(cat /proc/sys/kernel/random/boot_id)" > "$TUNNEL_OWNER_FILE"
interface_index() { echo 43; }
if stop_tunnel >/dev/null; then fail 'replacement interface accepted'; fi
[[ ! -e "$TEST_TMP/privileged" ]] || fail 'replacement interface touched'
interface_index() { echo 42; }
if stop_tunnel >/dev/null; then fail 'failed down reported success'; fi
[[ -f "$TUNNEL_OWNER_FILE" ]] || fail 'ownership discarded on failure'
rm "$TUNNEL_OWNER_FILE" "$TEST_TMP/privileged"

# Real process identity: a stale start time must not authorize a signal.
write_process_record "$PID_FILE" "$$"
process_record_matches "$PID_FILE" "$$" || fail 'identity mismatch'
printf '%s\nstale\n' "$$" > "$PID_FILE"
if process_record_matches "$PID_FILE" "$$"; then fail 'stale PID accepted'; fi
if stop_proxy >/dev/null; then fail 'unverified live process accepted'; fi
[[ -f "$PID_FILE" ]] || fail 'unverified process record removed'
rm "$PID_FILE"

# An unavailable firewall is a fatal startup failure before 3proxy starts.
if (
    load_config() { :; }
    check_deps() { :; }
    block_ipv6() { :; }
    prepare_network_targets() { :; }
    build_allowed_ips() { :; }
    start_tunnel() { :; }
    start_guard() { return 1; }
    start_proxy() { touch "$TEST_TMP/proxy-started"; }
    do_start >/dev/null
); then fail 'startup accepted missing firewall'; fi
[[ ! -e "$TEST_TMP/proxy-started" ]] || fail 'proxy started without firewall'

# Capture the actual generated nft batch: numeric ifindex also blocks a new
# interface reusing the VPN name. No real firewall commands are executed.
PROXY_CONNECT_HOST=203.0.113.10
PROXY_PORT=3128
sudo() {
    [[ "$*" == 'nft -f -' ]] || return 1
    cat > "$TEST_TMP/rules.nft"
}
start_guard
grep -Fq "meta skuid $UID ip daddr 203.0.113.10 tcp dport 3128 meta oif != 42 counter drop" "$TEST_TMP/rules.nft" || fail 'missing fail-closed rule'
[[ -s "$GUARD_FILE" ]] || fail 'guard recovery state absent'

# Guard stays installed when proxy shutdown fails; tunnel must stay untouched.
PROXY_OWNED=1
TUNNEL_OWNED=1
stop_proxy() { return 1; }
stop_tunnel() { fail 'tunnel removed while proxy alive'; }
stop_guard() { fail 'guard removed while proxy alive'; }
cleanup >/dev/null
[[ -s "$GUARD_FILE" ]] || fail 'guard record lost'

# Successful cleanup order is process -> tunnel -> guard.
CLEANUP_DONE=0
stop_proxy() { printf 'proxy\n' >> "$TEST_TMP/order"; }
stop_tunnel() { printf 'tunnel\n' >> "$TEST_TMP/order"; }
stop_guard() { printf 'guard\n' >> "$TEST_TMP/order"; }
cleanup >/dev/null
[[ "$(<"$TEST_TMP/order")" == $'proxy\ntunnel\nguard' ]] || fail 'unsafe cleanup order'
echo 'OK: security regression tests passed'
