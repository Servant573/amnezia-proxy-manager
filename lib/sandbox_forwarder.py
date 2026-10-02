"""Raw TCP relay between several LISTEN=TARGET address pairs.

Stdlib only. Each argument is HOST:PORT=HOST:PORT. The relay is
protocol-agnostic (HTTP and SOCKS are just TCP), so one instance bridges both
local proxy ports. It runs in the host netns to expose the host 3proxy on the
sandbox veth address, without touching 3proxy's own loopback-only listeners.
"""
import socket
import sys
import threading


def parse_addr(text):
    host, sep, port = text.rpartition(":")
    if not sep or not host or not port:
        raise ValueError("некорректный адрес: %s" % text)
    return host, int(port)


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
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


def relay(client, target):
    upstream = None
    try:
        upstream = socket.create_connection(target, timeout=10)
        client.settimeout(None)
        upstream.settimeout(None)
        t1 = threading.Thread(target=pump, args=(client, upstream), daemon=True)
        t2 = threading.Thread(target=pump, args=(upstream, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except OSError:
        pass
    finally:
        if upstream is not None:
            upstream.close()
        client.close()


def serve(listen, target):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(listen)
    except OSError as exc:
        sys.stderr.write("bind %s: %s\n" % (listen, exc))
        return
    sock.listen(128)
    while True:
        try:
            client, _ = sock.accept()
        except OSError:
            break
        threading.Thread(target=relay, args=(client, target), daemon=True).start()


def main(argv):
    if len(argv) < 2:
        raise SystemExit("usage: sandbox_forwarder.py LISTEN=TARGET [LISTEN=TARGET ...]")
    for spec in argv[1:]:
        left, sep, right = spec.partition("=")
        if not sep or not right:
            raise SystemExit("ожидается LISTEN=TARGET, получено: %s" % spec)
        threading.Thread(target=serve, args=(parse_addr(left), parse_addr(right)),
                         daemon=True).start()
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main(sys.argv)
