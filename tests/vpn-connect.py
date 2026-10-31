"""Handshake readiness and deadlines; no real VPN or network changes."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = r'''
source "$1/bin/amnezia-proxy"
LOG_TO_FILE=0
WG_INTERFACE=test-vpn
PUBLIC_KEY=expected-peer
ENDPOINT_CONNECT_HOST=198.51.100.1
ENDPOINT_PORT=51820
VPN_CONNECT_TIMEOUT=1
PERSISTENTKEEPALIVE=0
VPN_STARTED_AT=$(date +%s)
vpn_connect_command() {
    if [[ "$1" == set ]]; then
        [[ "$CASE" != init-failure ]]
        return $?
    fi
    case "$CASE" in
        connected|restore-failure) printf '%s %s\n' "$PUBLIC_KEY" "$(date +%s)" ;;
        delayed)
            if [[ -e "$MARKER" ]]; then printf '%s %s\n' "$PUBLIC_KEY" "$(date +%s)"; else touch "$MARKER"; printf '%s 0\n' "$PUBLIC_KEY"; fi ;;
        stale) printf '%s %s\n' "$PUBLIC_KEY" "$((VPN_STARTED_AT - 300))" ;;
        wrong-peer) printf 'other-peer %s\n' "$(date +%s)" ;;
        inspect-failure) return 1 ;;
        *) printf '%s 0\n' "$PUBLIC_KEY" ;;
    esac
}
run_privileged() {
    printf '%s\n' "$*" > "$RESTORED"
    [[ "$CASE" != restore-failure ]]
}
if [[ "$CASE" == delayed ]]; then VPN_CONNECT_TIMEOUT=3; fi
vpn_wait_connected
'''
for case in ('connected', 'delayed', 'timeout', 'stale', 'wrong-peer',
             'inspect-failure', 'init-failure', 'restore-failure'):
    with tempfile.TemporaryDirectory() as directory:
        env = dict(os.environ, CASE=case, MARKER=f'{directory}/attempt', RESTORED=f'{directory}/restored')
        start = time.monotonic()
        result = subprocess.run(['bash', '-c', SCRIPT, '_', str(ROOT)], env=env,
                                capture_output=True, timeout=6)
        success = case in ('connected', 'delayed')
        assert (result.returncode == 0) == success, (case, result)
        assert time.monotonic() - start < 5, case
        restored = Path(directory, 'restored').read_text()
        assert restored.endswith('persistent-keepalive 0\n'), (case, restored)
        if case in ('timeout', 'stale', 'wrong-peer'):
            assert b'198.51.100.1:51820' in result.stdout, result
print('OK: VPN handshake success/delay, deadline, stale/wrong peer, command errors and keepalive restoration')

# Exercise the real deadline wrapper with a hung AWG command, without sudo.
with tempfile.TemporaryDirectory() as directory:
    awg = Path(directory, 'awg')
    awg.write_text('#!/bin/sh\nexec sleep 5\n')
    awg.chmod(0o755)
    env = dict(os.environ, PATH=f'{directory}:{os.environ["PATH"]}')
    script = r'''
source "$1/bin/amnezia-proxy"
LOG_TO_FILE=0
WG_INTERFACE=test-vpn
PUBLIC_KEY=expected-peer
ENDPOINT_CONNECT_HOST=198.51.100.1
ENDPOINT_PORT=51820
VPN_CONNECT_TIMEOUT=1
PERSISTENTKEEPALIVE=25
sudo() { shift; "$@"; }
run_privileged() { return 0; }
vpn_wait_connected
'''
    start = time.monotonic()
    result = subprocess.run(['bash', '-c', script, '_', str(ROOT)], env=env,
                            capture_output=True, timeout=4)
    assert result.returncode != 0 and time.monotonic() - start < 3, result
print('OK: a hung AWG command cannot overrun the connection deadline')
