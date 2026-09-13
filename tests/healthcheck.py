"""Local TLS/proxy regressions using real curl, without Internet access."""
import http.server
import os
from pathlib import Path
import socketserver
import ssl
import subprocess
import tempfile
import threading


class Destination(http.server.BaseHTTPRequestHandler):
    hits = 0

    def log_message(self, *_):
        pass

    def do_GET(self):
        type(self).hits += 1
        self.send_response({"/ok": 204, "/redirect": 302, "/error": 503}[self.path])
        self.send_header("Content-Length", "0")
        self.end_headers()


class RejectingHTTP(Destination):
    connects = 0

    def do_CONNECT(self):
        type(self).connects += 1
        self.send_response(407)
        self.end_headers()


class RejectingSOCKS(socketserver.BaseRequestHandler):
    connects = 0

    def handle(self):
        type(self).connects += 1
        self.request.recv(512)
        self.request.sendall(b"\x05\xff")


root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as temp:
    cert, key = Path(temp) / "cert.pem", Path(temp) / "key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(key), "-out", str(cert), "-days", "1",
                    "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # If -q is missing, curl fails before connecting. Connection counts catch
    # that false-positive failure as well as a NO_PROXY bypass.
    (Path(temp) / ".curlrc").write_text("--invalid-option-for-regression-test\n")
    tls = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Destination)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    http_proxy = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RejectingHTTP)
    socks_proxy = socketserver.ThreadingTCPServer(("127.0.0.1", 0), RejectingSOCKS)
    servers = [tls, http_proxy, socks_proxy]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, NO_PROXY="*", no_proxy="*", CURL_HOME=temp,
               CURL_CA_BUNDLE=str(cert), LOCAL_HTTP_PORT=str(http_proxy.server_port),
               LOCAL_SOCKS_PORT=str(socks_proxy.server_address[1]))

    def invoke(function, path="/ok"):
        current = dict(env, HEALTHCHECK_URL=f"https://localhost:{tls.server_port}{path}")
        return subprocess.run(["bash", "-c", 'source bin/amnezia-proxy; ' + function],
                              cwd=root, env=current, capture_output=True, timeout=15).returncode

    try:
        assert invoke("proxy_health_request --proxy ''") == 0, "2xx rejected"
        assert invoke("proxy_health_request --proxy ''", "/redirect") != 0, "302 accepted"
        assert invoke("proxy_health_request --proxy ''", "/error") != 0, "503 accepted"
        direct_hits = Destination.hits
        assert invoke("http_proxy_healthy") != 0, "HTTP bypassed rejecting proxy"
        assert RejectingHTTP.connects == 1, "HTTP proxy was not contacted"
        assert invoke("socks_proxy_healthy") != 0, "SOCKS bypassed rejecting proxy"
        assert RejectingSOCKS.connects == 1, "SOCKS proxy was not contacted"
        assert Destination.hits == direct_hits, "healthcheck contacted target directly"
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
print("OK: real curl honors proxy despite NO_PROXY/*curlrc; rejects redirects and errors")
