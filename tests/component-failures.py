"""Startup fault injection: own resources unwind; proxy never bypasses VPN."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = r'''
source "$1/bin/amnezia-proxy"
init_paths
trap cleanup EXIT
check_deps() { [[ "$FAIL_AT" != deps ]]; }
step() {
    printf '%s\n' "$1" >> "$RUNTIME_DIR/calls"
    [[ "$FAIL_AT" != "$1" ]]
}
block_ipv6() { IPV6_OWNED=1; touch "$IPV6_GUARD_FILE"; step ipv6; }
prepare_network_targets() { PROXY_IPS=203.0.113.1; step prepare; }
ensure_proxy_ports_available() { step ports; }
build_allowed_ips() { step routes; }
vpn_wait_connected() { step handshake; }
start_tunnel() { TUNNEL_OWNED=1; touch "$TUNNEL_OWNER_FILE"; step vpn; }
start_guard() { GUARD_OWNED=1; touch "$GUARD_FILE"; step guard; }
start_proxy() { PROXY_OWNED=1; touch "$PID_FILE"; step proxy; }
run_startup_healthcheck() { step health; }
stop_proxy() { rm -f "$PID_FILE"; PROXY_OWNED=0; }
stop_tunnel() { rm -f "$TUNNEL_OWNER_FILE"; TUNNEL_OWNED=0; }
stop_guard() { rm -f "$GUARD_FILE"; GUARD_OWNED=0; }
unblock_ipv6() { rm -f "$IPV6_GUARD_FILE"; IPV6_OWNED=0; }
do_start
'''
for step in ('deps', 'ipv6', 'prepare', 'ports', 'routes', 'vpn', 'handshake', 'guard', 'proxy', 'health'):
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        config = base / 'config'
        config.write_bytes((ROOT / 'tests/fixtures/valid.conf').read_bytes())
        config.chmod(0o600)
        env = dict(os.environ, FAIL_AT=step, AMNEZIA_PROXY_CONFIG=str(config),
                   AMNEZIA_PROXY_RUNTIME_DIR=str(base / 'runtime'),
                   AMNEZIA_PROXY_STATE_DIR=str(base / 'state'),
                   AMNEZIA_PROXY_CACHE_DIR=str(base / 'cache'))
        result = subprocess.run(['bash', '-c', SCRIPT, '_', str(ROOT)],
                                env=env, capture_output=True, timeout=5)
        assert result.returncode != 0, (step, result)
        for record in ('session.state', 'tunnel.owner', 'guard.owner', '3proxy.pid', 'ipv6.owner'):
            assert not (base / 'runtime' / record).exists(), (step, record, result)
        calls = base / 'runtime/calls'
        if step in ('deps', 'ipv6', 'prepare', 'ports', 'routes', 'vpn', 'handshake', 'guard') and calls.exists():
            assert 'proxy' not in calls.read_text().splitlines(), (step, result)
print('OK: startup failures unwind owned resources; no proxy fallback after VPN/guard failure')

# A missing interface must fail even if the ownership record is missing too.
with tempfile.TemporaryDirectory() as directory:
    env = dict(os.environ, AMNEZIA_PROXY_RUNTIME_DIR=directory,
               AMNEZIA_PROXY_STATE_DIR=directory, AMNEZIA_PROXY_CACHE_DIR=directory)
    script = r'''
source "$1/bin/amnezia-proxy"
init_paths
is_manager_running() { return 1; }
do_start() { VPN_ON=1; PROXY_ON=0; }
interface_index() { return 1; }
run_manager
'''
    result = subprocess.run(['bash', '-c', script, '_', str(ROOT)], env=env,
                            capture_output=True, timeout=5)
    assert result.returncode != 0, result
print('OK: supervisor rejects missing VPN interface and missing ownership record')
