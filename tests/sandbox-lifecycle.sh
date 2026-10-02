#!/bin/bash
# No kernel network mutations: all namespace/link operations below are mocked.
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
log() { :; }

SANDBOX_NETNS_NAME=audit-test
SANDBOX_HOST_IF=ah0123456789a
SANDBOX_NS_IF=an0123456789a
SANDBOX_HOST_IP=10.200.0.1
SANDBOX_NS_ID=10:20
SANDBOX_HOST_INDEX=42
SANDBOX_PEER_INDEX=43
MOCK_NS=10:20; MOCK_HOST=42; MOCK_PEER=""
delete_failure=0
namespace_pids=""
sandbox_namespace_identity() { [[ -n "$MOCK_NS" ]] || return 1; printf '%s' "$MOCK_NS"; }
sandbox_link_identity() {
    case "$1" in
        "$SANDBOX_HOST_IF") [[ -n "$MOCK_HOST" ]] || return 1; printf '%s' "$MOCK_HOST" ;;
        "$SANDBOX_NS_IF") [[ -n "$MOCK_PEER" ]] || return 1; printf '%s' "$MOCK_PEER" ;;
        *) return 1 ;;
    esac
}
run_privileged() {
    printf '%s\n' "$*" >> "$TEST_TMP/calls"
    case "$*" in
        'ip link del '*)
            (( delete_failure == 0 )) || return 1
            MOCK_HOST=""; MOCK_PEER="" ;;
        'ip netns pids '*) printf '%s' "$namespace_pids" ;;
        'ip netns del '*) MOCK_NS="" ;;
        *) fail "unexpected privileged operation: $*" ;;
    esac
}

# A replacement interface must not be deleted even if its name matches.
sandbox_write_owner
MOCK_HOST=99
if sandbox_netns_destroy; then fail 'replacement interface accepted'; fi
[[ -e "$SANDBOX_FILE" && ! -e "$TEST_TMP/calls" ]] || fail 'foreign resource touched'
MOCK_HOST=42; MOCK_NS=10:99
if sandbox_netns_destroy; then fail 'replacement namespace accepted'; fi
[[ ! -e "$TEST_TMP/calls" ]] || fail 'foreign namespace touched'

# Intent-only ownership is never enough, including crash recovery.
MOCK_NS=10:20; SANDBOX_NS_ID=pending
sandbox_write_owner
if sandbox_netns_destroy; then fail 'intent adopted existing namespace'; fi
[[ ! -e "$TEST_TMP/calls" ]] || fail 'intent caused deletion'
SANDBOX_NS_ID=10:20
sandbox_write_owner

# Keep state on failed delete and when remaining namespace processes exist.
delete_failure=1
if sandbox_netns_destroy; then fail 'failed link deletion reported success'; fi
[[ -e "$SANDBOX_FILE" ]] || fail 'cleanup retry record lost'
delete_failure=0; namespace_pids=123
if sandbox_netns_destroy; then fail 'occupied namespace removed'; fi
[[ -e "$SANDBOX_FILE" && "$MOCK_NS" == 10:20 ]] || fail 'occupied namespace state lost'
namespace_pids=""
sandbox_netns_destroy
[[ ! -e "$SANDBOX_FILE" && -z "$MOCK_NS" ]] || fail 'retry did not finish'
sandbox_netns_destroy

# Reject legacy records instead of guessing which resources they own.
printf 'audit-test apm0 10.200.0.1 %s\n%s\n%s\n' \
    "$(cat /proc/sys/kernel/random/boot_id)" "$$" "$(process_identity "$$")" > "$SANDBOX_FILE"
if sandbox_netns_destroy; then fail 'legacy state auto-adopted'; fi
rm -f "$SANDBOX_FILE"

# A pre-existing namespace fails before intent creation and never calls sudo.
MOCK_NS=10:20
sudo() { fail 'sudo called for pre-existing namespace'; }
if (sandbox_netns_create) >/dev/null 2>&1; then fail 'existing namespace accepted'; fi
[[ ! -e "$SANDBOX_FILE" ]] || fail 'existing namespace got an owner record'

# A failed add does not authorize deleting a concurrently created namespace.
if (
    MOCK_NS=""
    sudo() { MOCK_NS=77:88; return 1; }
    trap 'sandbox_run_cleanup || true' EXIT
    sandbox_netns_create
) >/dev/null 2>&1; then fail 'failed namespace add accepted'; fi
[[ -e "$SANDBOX_FILE" ]] || fail 'ambiguous collision state discarded'
rm -f "$SANDBOX_FILE"

# Negative PIDs and foreign live processes are never signalled.
printf '%s\n' '-123' > "$FW_PID_FILE"
if sandbox_stop_forwarder; then fail 'negative PID accepted'; fi
rm -f "$FW_PID_FILE"
sleep 30 &
other=$!
trap 'kill "$other" 2>/dev/null || true; wait "$other" 2>/dev/null || true; rm -rf -- "$TEST_TMP"' EXIT
write_process_record "$FW_PID_FILE" "$other"
if sandbox_stop_forwarder; then fail 'foreign command accepted'; fi
kill -0 "$other" || fail 'foreign process killed'
printf '%s\n%s\n' "$other" 'old-boot:1' > "$FW_PID_FILE"
sandbox_stop_forwarder
kill -0 "$other" || fail 'reused PID killed'

# Session lock excludes other operations and is released on failure/cleanup.
sandbox_acquire_lock
if bash -c 'source "$1"; source "$2"; sandbox_acquire_lock' _ \
    "$PROJECT_ROOT/lib/paths.sh" "$PROJECT_ROOT/lib/sandbox.sh" >/dev/null 2>&1; then
    fail 'parallel session got lock'
fi
sandbox_release_lock
sandbox_acquire_lock
sandbox_release_lock

# stop refuses an active sandbox before stopping the proxy.
sandbox_acquire_lock
is_manager_running() { touch "$TEST_TMP/manager-checked"; return 0; }
if (do_stop) >/dev/null 2>&1; then fail 'stop accepted active session'; fi
[[ ! -e "$TEST_TMP/manager-checked" ]] || fail 'manager touched before checking session lock'
sandbox_release_lock
sandbox_stop() { return 1; }
stop_proxy() { touch "$TEST_TMP/proxy-stopped"; }
if stop_components; then fail 'active sandbox stop reported success'; fi
[[ ! -e "$TEST_TMP/proxy-stopped" ]] || fail 'proxy stopped despite active sandbox'
echo 'OK: sandbox ownership, retryable cleanup, PID identity and locks'
