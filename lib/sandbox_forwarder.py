"""Raw TCP relay between several LISTEN=TARGET address pairs.

Stdlib only. Each argument is HOST:PORT=HOST:PORT. The relay is
protocol-agnostic (HTTP and SOCKS are just TCP), so one instance bridges both
local proxy ports. It runs in the host netns to expose the host 3proxy on the
sandbox veth address, without touching 3proxy's own loopback-only listeners.

Optional `--log FILE` logs safe metadata once per connection: HTTP method,
validated CONNECT authority, or a socks/tcp marker. Never logs request paths,
query strings, credentials, headers or arbitrary payload. Logging is passive
and errors do not interrupt transport.
"""
import datetime
import os
import re
import socket
import stat
import sys
import threading


LOG_PATH = None
LOG_LOCK = threading.Lock()
LOG_WARNED = False
HOST_LABEL = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?")
HTTP_METHODS = {b"CONNECT", b"GET", b"HEAD", b"POST", b"PUT", b"PATCH", b"DELETE", b"OPTIONS", b"TRACE"}


def parse_addr(text):
    host, sep, port = text.rpartition(":")
    if not sep or not host or not port:
        raise ValueError("некорректный адрес: %s" % text)
    return host, int(port)


def log_line(msg):
    global LOG_WARNED
    if not LOG_PATH:
        return
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with LOG_LOCK:
        fd = None
        try:
            fd = os.open(LOG_PATH, os.O_WRONLY | os.O_APPEND | os.O_CREAT |
                         os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o600)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
                raise OSError("unsafe log file")
            os.fchmod(fd, 0o600)
            line = ("%s %s\n" % (ts, msg)).encode("utf-8")
            if os.write(fd, line) != len(line):
                raise OSError("partial log write")
        except OSError:
            if not LOG_WARNED:
                # No raw exception or payload, and no warning per connection.
                try:
                    sys.stderr.write("sandbox log unavailable; relay continues\n")
                except (OSError, ValueError):
                    pass
                LOG_WARNED = True
        finally:
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass


def request_label(data):
    """Conservative first-chunk metadata; incomplete requests are just tcp."""
    if not data:
        return "no-data"
    if data[:1] in (b"\x04", b"\x05"):
        return "socks"
    head, newline, _ = data.partition(b"\n")
    if not newline:
        return "tcp"
    fields = head.rstrip(b"\r").split(b" ")
    if len(fields) != 3 or fields[0] not in HTTP_METHODS or fields[2] not in (b"HTTP/1.0", b"HTTP/1.1"):
        return "tcp"
    method = fields[0].decode("ascii")
    if method != "CONNECT":
        return method
    try:
        authority = fields[1].decode("ascii")
    except UnicodeDecodeError:
        return method
    host, sep, port = authority.rpartition(":")
    if (sep and len(host) <= 253 and host and
            all(HOST_LABEL.fullmatch(label) for label in host.split(".")) and
            re.fullmatch(r"[1-9][0-9]{0,4}", port) and int(port) <= 65535):
        return "%s %s:%s" % (method, host, port)
    return method


def pump(src, dst, on_first_chunk=None):
    try:
        while True:
            data = src.recv(65536)
            if on_first_chunk is not None:
                on_first_chunk(data)
                on_first_chunk = None
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def relay(client, target, listen_port):
    upstream = None
    src = "?"
    try:
        try:
            src = "%s:%d" % client.getpeername()
        except OSError:
            src = "?"
        upstream = socket.create_connection(target, timeout=10)
        client.settimeout(None)
        upstream.settimeout(None)

        def log_first(data):
            log_line("[%d] %s %s" % (listen_port, src, request_label(data)))

        t1 = threading.Thread(target=pump, args=(client, upstream, log_first), daemon=True)
        t2 = threading.Thread(target=pump, args=(upstream, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except OSError:
        log_line("[%d] %s connect-failed" % (listen_port, src))
    finally:
        if upstream is not None:
            upstream.close()
        client.close()


def bind_listener(listen):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(listen)
        sock.listen(128)
    except OSError:
        sock.close()
        raise
    return sock


def serve(sock, target):
    listen_port = sock.getsockname()[1]
    while True:
        try:
            client, _ = sock.accept()
        except OSError:
            break
        threading.Thread(target=relay, args=(client, target, listen_port), daemon=True).start()


def main(argv):
    global LOG_PATH
    args = argv[1:]
    ready = None
    while args and args[0] in ("--log", "--ready"):
        if len(args) < 2:
            raise SystemExit("%s требует путь" % args[0])
        if args[0] == "--log":
            LOG_PATH = args[1]
        else:
            ready = args[1]
        args = args[2:]
    if not args:
        raise SystemExit("usage: sandbox_forwarder.py [--log FILE] LISTEN=TARGET [LISTEN=TARGET ...]")
    listeners = []
    try:
        # Bind every required port before advertising readiness. A partial
        # listener set is never a successful launch.
        for spec in args:
            left, sep, right = spec.partition("=")
            if not sep or not right:
                raise ValueError("ожидается LISTEN=TARGET, получено: %s" % spec)
            target = parse_addr(right)
            listeners.append((bind_listener(parse_addr(left)), target))
        for sock, target in listeners:
            threading.Thread(target=serve, args=(sock, target), daemon=True).start()
        if ready:
            with open(ready, "x") as fh:
                fh.write("%s\n" % os.getpid())
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    except (OSError, ValueError) as exc:
        raise SystemExit("forwarder startup failed: %s" % exc) from exc
    finally:
        for sock, _ in listeners:
            sock.close()


if __name__ == "__main__":
    main(sys.argv)
