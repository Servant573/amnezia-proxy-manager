"""Real runner signals with mocked networking; never enters a host netns."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SETUP = r'''
set -euo pipefail
source "$1/bin/amnezia-proxy"
init_paths
load_config() { :; }
check_sandbox_deps() { :; }
is_proxy_running() { return 0; }
is_tunnel_up() { return 0; }
read_active_proxy_ports() { :; }
sandbox_netns_create() { SANDBOX_OWNED=1; touch "$SANDBOX_FILE"; }
sandbox_netns_destroy() { rm -f "$SANDBOX_FILE"; }
sandbox_start_forwarder() { :; }
sandbox_verify() { :; }
sandbox_build_bwrap() { :; }
sandbox_run_agent() {
    printf '%s' "$BASHPID" > "$RUNTIME_DIR/agent.started"
    exec sleep 30
}
do_run ignored
'''

with tempfile.TemporaryDirectory() as directory:
    env = dict(os.environ, AMNEZIA_PROXY_RUNTIME_DIR=directory,
               AMNEZIA_PROXY_STATE_DIR=directory, AMNEZIA_PROXY_CACHE_DIR=directory)
    process = subprocess.Popen(['bash', '-c', SETUP, '_', str(ROOT)], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    child = None
    child_start = None
    try:
        marker = Path(directory) / 'agent.started'
        deadline = time.monotonic() + 5
        while not marker.exists():
            assert process.poll() is None, process.communicate()
            assert time.monotonic() < deadline, 'runner did not start'
            time.sleep(0.02)
        child = int(marker.read_text())
        child_start = Path(f'/proc/{child}/stat').read_text().rsplit(') ', 1)[1].split()[19]
        # Let the parent record child identity before sending TERM.
        time.sleep(0.1)
        process.send_signal(signal.SIGTERM)
        output, error = process.communicate(timeout=5)
        assert process.returncode == 143, (process.returncode, output, error)
        assert not Path(directory, 'sandbox.owner').exists()
        assert not Path(f'/proc/{child}').exists(), 'agent child survived TERM'
        result = subprocess.run(['flock', '-n', str(Path(directory) / 'sandbox.lock'), 'true'])
        assert result.returncode == 0, 'session lock leaked'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if child and Path(f'/proc/{child}').exists():
            try:
                current_start = Path(f'/proc/{child}/stat').read_text().rsplit(') ', 1)[1].split()[19]
                if current_start == child_start:
                    os.kill(child, signal.SIGTERM)
            except ProcessLookupError:
                pass

    # Failure before relay startup must still invoke the early EXIT cleanup.
    failure = SETUP.replace('sandbox_start_forwarder() { :; }',
                            'sandbox_start_forwarder() { die "synthetic startup failure"; }')
    result = subprocess.run(['bash', '-c', failure, '_', str(ROOT)], env=env,
                            capture_output=True, timeout=5)
    assert result.returncode != 0
    assert not Path(directory, 'sandbox.owner').exists(), 'early failure lost cleanup'

    # A background runner must keep stdin for interactive coding agents.
    interactive = SETUP.replace('    exec sleep 30',
                                '    IFS= read -r response\n    [[ "$response" == hello ]]')
    result = subprocess.run(['bash', '-c', interactive, '_', str(ROOT)], env=env,
                            input=b'hello\n', capture_output=True, timeout=5)
    assert result.returncode == 0, ('runner lost stdin', result.stdout, result.stderr)

print('OK: TERM stops own agent, releases lock, early rollback and inherited stdin')
