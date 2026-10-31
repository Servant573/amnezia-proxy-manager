"""Real proxy-only manager lifecycle with a synthetic local 3proxy process."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    fake = base / '3proxy'
    fake.write_text('''#!/usr/bin/python3
import re, socket, sys, time
text = open(sys.argv[1]).read()
listeners = []
for port in re.findall(r'^(?:proxy|socks) -p(\\d+)', text, re.M):
    s = socket.socket()
    s.bind(('127.0.0.1', int(port)))
    s.listen()
    listeners.append(s)
while True:
    time.sleep(1)
''')
    fake.chmod(0o755)
    probes = [socket.socket(), socket.socket()]
    for s in probes:
        s.bind(('127.0.0.1', 0))
    ports = [s.getsockname()[1] for s in probes]
    for s in probes:
        s.close()
    config = base / 'config'
    config.write_text(f'''VPN_ON=false
PROXY_ON=true
BLOCK_IPV6=off
PROXY_STRING=203.0.113.1:3128:user:synthetic-password
LOCAL_HTTP_PORT={ports[0]}
LOCAL_SOCKS_PORT={ports[1]}
STARTUP_HEALTHCHECK=off
''')
    config.chmod(0o600)
    env = dict(os.environ, PATH=f'{base}:{os.environ["PATH"]}',
               AMNEZIA_PROXY_CONFIG=str(config),
               AMNEZIA_PROXY_RUNTIME_DIR=str(base / 'runtime'),
               AMNEZIA_PROXY_STATE_DIR=str(base / 'state'),
               AMNEZIA_PROXY_CACHE_DIR=str(base / 'cache'))
    cli = str(ROOT / 'bin/amnezia-proxy')
    with (base / 'output').open('w+') as output:
        manager = subprocess.Popen([cli, 'start'], env=env, stdout=output, stderr=output)
        try:
            snapshot = base / 'runtime/session.state'
            deadline = time.monotonic() + 8
            while not snapshot.exists() or 'SESSION_PHASE=ready\n' not in snapshot.read_text():
                assert manager.poll() is None, (base / 'output').read_text()
                assert time.monotonic() < deadline, (base / 'output').read_text()
                time.sleep(0.05)
            assert not (base / 'runtime/tunnel.owner').exists()
            assert not (base / 'runtime/guard.owner').exists()
            config.write_text('VPN_ON=false\nPROXY_ON=false\n')
            result = subprocess.run([cli, 'restart'], env=env, capture_output=True, timeout=5)
            assert result.returncode != 0 and manager.poll() is None
            config.unlink()
            # status uses runtime, including ports, even with no source config.
            result = subprocess.run([cli, 'status'], env=env, capture_output=True, timeout=25)
            assert result.returncode in (1, 2), result
            assert b'VPN: DISABLED' in result.stdout, result
            result = subprocess.run([cli, 'stop'], env=env, capture_output=True, timeout=10)
            assert result.returncode == 0, result
            manager.wait(timeout=5)
            assert not snapshot.exists()
            assert not (base / 'runtime/3proxy.pid').exists()
        finally:
            if manager.poll() is None:
                manager.terminate()
                manager.wait(timeout=10)
print('OK: real proxy-only start, invalid restart preservation and config-independent stop')
