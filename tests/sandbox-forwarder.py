"""Loopback-only regression tests; no host network configuration is changed."""
import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'lib/sandbox_forwarder.py'
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('sandbox_forwarder', SCRIPT)
forwarder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(forwarder)

with tempfile.TemporaryDirectory() as directory:
    ready = Path(directory) / 'ready'
    with socket.socket() as occupied:
        occupied.bind(('127.0.0.1', 0))
        occupied.listen()
        port = occupied.getsockname()[1]
        # Second bind fails; there must be neither READY nor a hanging PID.
        result = subprocess.run([sys.executable, str(SCRIPT), '--ready', str(ready),
                                 '127.0.0.1:0=127.0.0.1:1',
                                 f'127.0.0.1:{port}=127.0.0.1:1'],
                                capture_output=True, timeout=5)
        assert result.returncode != 0 and not ready.exists(), result

    with socket.socket() as upstream:
        upstream.bind(('127.0.0.1', 0))
        upstream.listen()
        def echo():
            connection, _ = upstream.accept()
            with connection:
                data = connection.recv(4096)
                connection.sendall(data)
        echo_thread = threading.Thread(target=echo, daemon=True)
        echo_thread.start()
        with forwarder.bind_listener(('127.0.0.1', 0)) as listener:
            thread = threading.Thread(target=forwarder.serve,
                                      args=(listener, upstream.getsockname()), daemon=True)
            thread.start()
            with socket.create_connection(listener.getsockname(), timeout=3) as client:
                message = b'CONNECT example.invalid:443 HTTP/1.1\r\n\r\n'
                client.sendall(message)
                client.shutdown(socket.SHUT_WR)
                received = b''
                while True:
                    chunk = client.recv(4096)
                    if not chunk:
                        break
                    received += chunk
                assert received == message
        echo_thread.join(timeout=3)

    # Exercise actual Bash startup/stop, including READY PID and process record.
    holders = [socket.socket(), socket.socket()]
    for holder in holders:
        holder.bind(('127.0.0.1', 0))
    ports = [holder.getsockname()[1] for holder in holders]
    for holder in holders:
        holder.close()
    env = dict(os.environ, AMNEZIA_PROXY_RUNTIME_DIR=directory,
               AMNEZIA_PROXY_STATE_DIR=directory, AMNEZIA_PROXY_CACHE_DIR=directory)
    shell = r'''
set -euo pipefail
source "$1/bin/amnezia-proxy"
init_paths
SANDBOX_HOST_IP=127.0.0.1
SANDBOX_HTTP_PORT=$2
SANDBOX_SOCKS_PORT=$3
trap 'sandbox_stop_forwarder || true' EXIT
sandbox_start_forwarder
pid=$(read_pid "$FW_PID_FILE")
[[ "$(cat "$RUNTIME_DIR/sandbox-forwarder.ready")" == "$pid" ]]
process_record_matches "$FW_PID_FILE" "$pid"
sandbox_stop_forwarder
[[ ! -e "$FW_PID_FILE" && ! -e "$RUNTIME_DIR/sandbox-forwarder.ready" ]]
'''
    subprocess.run(['bash', '-c', shell, '_', str(ROOT), *map(str, ports)],
                   env=env, check=True, timeout=10)

print('OK: all-listener startup, raw relay, READY identity and real forwarder stop')
