"""Metadata privacy, safe writer and passive relay tests (loopback only)."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('sandbox_forwarder', ROOT / 'lib/sandbox_forwarder.py')
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

cases = [
    (b'CONNECT api.example.com:443 HTTP/1.1\r\n\r\n', 'CONNECT api.example.com:443'),
    (b'GET http://user:secret@example.com/private?token=SECRET HTTP/1.1\r\n\r\n', 'GET'),
    (b'POST /private?token=SECRET HTTP/1.1\r\nAuthorization: Bearer SECRET\r\n\r\nSECRET', 'POST'),
    (b'CONNECT user:secret@example.com:443 HTTP/1.1\r\n', 'CONNECT'),
    (b'CONNECT example.com:99999 HTTP/1.1\r\n', 'CONNECT'),
    (b'CONNECT example.com:443/path?secret HTTP/1.1\r\n', 'CONNECT'),
    (b'CONNECT example.com:443 HT', 'tcp'),
    (b'Authorization: Bearer SECRET\r\n', 'tcp'),
    (b'printable raw SECRET', 'tcp'),
    (b'\x05\x01\x00', 'socks'),
    (b'\xff\x00SECRET\n', 'tcp'),
    (b'', 'no-data'),
]
for payload, expected in cases:
    assert relay.request_label(payload) == expected, (payload, relay.request_label(payload))

with tempfile.TemporaryDirectory() as directory:
    log = Path(directory) / 'sandbox.log'
    relay.LOG_PATH = str(log)
    previous_umask = os.umask(0o022)
    try:
        # Explicit mode must protect standalone use with a permissive umask.
        relay.log_line('CONNECT api.example.com:443')
    finally:
        os.umask(previous_umask)
    assert log.stat().st_mode & 0o777 == 0o600
    for payload, _ in cases:
        relay.log_line(relay.request_label(payload))
    contents = log.read_text()
    assert 'SECRET' not in contents and 'token=' not in contents and 'user:' not in contents

    target = Path(directory) / 'unrelated'
    target.write_text('keep')
    link = Path(directory) / 'log-link'
    link.symlink_to(target)
    relay.LOG_PATH = str(link)
    relay.LOG_WARNED = False
    warnings = io.StringIO()
    with contextlib.redirect_stderr(warnings):
        relay.log_line('tcp')
        relay.log_line('tcp')
    assert target.read_text() == 'keep' and warnings.getvalue().count('relay continues') == 1

    link.unlink()
    os.link(target, link)
    relay.LOG_WARNED = False
    with contextlib.redirect_stderr(io.StringIO()):
        relay.log_line('tcp')
    assert target.read_text() == 'keep'

    fifo = Path(directory) / 'fifo'
    os.mkfifo(fifo)
    relay.LOG_PATH = str(fifo)
    with contextlib.redirect_stderr(io.StringIO()):
        relay.log_line('tcp')  # Nonblocking; no FIFO reader needed.

    relay.LOG_PATH = str(log)
    relay.LOG_WARNED = False
    with mock.patch.object(relay.os, 'write', side_effect=OSError('SYNTHETIC_SECRET')):
        warnings = io.StringIO()
        with contextlib.redirect_stderr(warnings):
            relay.log_line('tcp')
    assert 'SYNTHETIC_SECRET' not in warnings.getvalue()

    def exchange(server_first, broken_log):
        relay.LOG_PATH = str(Path(directory) / 'missing' / 'log') if broken_log else str(log)
        relay.LOG_WARNED = False
        errors = []
        payload = b'GET http://example.invalid/?token=SECRET HTTP/1.1\r\n\r\n'
        with socket.socket() as upstream:
            upstream.bind(('127.0.0.1', 0))
            upstream.listen()
            def handle():
                try:
                    connection, _ = upstream.accept()
                    with connection:
                        connection.settimeout(3)
                        if server_first:
                            connection.sendall(b'banner\n')
                        received = b''
                        while len(received) < len(payload):
                            chunk = connection.recv(4096)
                            assert chunk, 'upstream prematurely closed'
                            received += chunk
                        assert received == payload
                        connection.sendall(received)
                except Exception as exc:
                    errors.append(exc)
            server = threading.Thread(target=handle, daemon=True)
            server.start()
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                listener.listen()
                def bridge():
                    client, _ = listener.accept()
                    relay.relay(client, upstream.getsockname(), listener.getsockname()[1])
                bridge_thread = threading.Thread(target=bridge, daemon=True)
                bridge_thread.start()
                with socket.create_connection(listener.getsockname(), timeout=3) as client:
                    if server_first:
                        client.settimeout(1)
                        assert client.recv(4096) == b'banner\n', 'banner delayed by logging'
                    client.settimeout(3)
                    client.sendall(payload)
                    client.shutdown(socket.SHUT_WR)
                    received = b''
                    while True:
                        chunk = client.recv(4096)
                        if not chunk:
                            break
                        received += chunk
                    assert received == payload, 'logging changed/dropped payload'
                bridge_thread.join(timeout=3)
                assert not bridge_thread.is_alive()
            server.join(timeout=3)
            assert not server.is_alive() and not errors, errors

    exchange(server_first=True, broken_log=False)
    with contextlib.redirect_stderr(io.StringIO()):
        exchange(server_first=False, broken_log=True)

print('OK: log redaction, private files, symlink/hardlink/FIFO rejection, passive/failing logging')
