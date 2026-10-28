"""Decode an AmneziaVPN ``vpn://`` link and print tunnel fields as ``KEY=value``.

Reads the link from stdin and prints one ``KEY=value`` line per tunnel field on
stdout, so the shell can consume it without evaluating arbitrary text. Values
are limited to the single-line fields used to build the AmneziaWG config; the
raw native config and anything not on the whitelist are never emitted.

Supported payloads (both share the same JSON structure):

* ``vpn://`` + base64url(JSON) — the official Amnezia client export;
* ``vpn://`` + base64url(4-byte big-endian length + zlib(JSON)) — the format
  produced by ``amneziawg-installer``.
"""

import base64
import json
import re
import sys
import zlib


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


IPV4_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$")


def decode_link(link):
    link = link.strip()
    if link.startswith("vpn://"):
        link = link[len("vpn://"):]
    encoded = link.replace("-", "+").replace("_", "/")
    encoded += "=" * (-len(encoded) % 4)
    try:
        raw = base64.b64decode(encoded)
    except Exception:
        fail("VPN_LINK: некорректная base64url-строка")

    stripped = raw.lstrip()
    if stripped[:1] in (b"{", b"["):
        payload = raw
    else:
        # amneziawg-installer prefixes the zlib stream with the uncompressed size.
        payload = None
        for offset in (4, 0):
            try:
                payload = zlib.decompress(raw[offset:])
                break
            except Exception:
                continue
        if payload is None:
            fail("VPN_LINK: payload не является JSON и не сжат zlib")

    try:
        return json.loads(payload.decode("utf-8"))
    except Exception:
        fail("VPN_LINK: некорректный JSON после декодирования")


def find_awg(config):
    containers = config.get("containers")
    if not isinstance(containers, list):
        return None
    default = config.get("defaultContainer")
    for container in containers:
        if isinstance(container, dict) and container.get("container") == default \
                and isinstance(container.get("awg"), dict):
            return container["awg"]
    for container in containers:
        if isinstance(container, dict) and isinstance(container.get("awg"), dict):
            return container["awg"]
    return None


def ipv4_only(text):
    if not text:
        return ""
    entries = [entry for entry in re.split(r"[\s,]+", text) if entry]
    return ",".join(entry for entry in entries if IPV4_RE.match(entry))


def parse_conf(text):
    """Extract single-line KEY = value fields from a WG-style .conf."""
    fields = {}
    section = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if "=" in line and section in ("Interface", "Peer"):
            key, _, value = line.partition("=")
            fields[key.strip()] = value.strip()
    return fields


def first_nonempty(*values):
    for value in values:
        if value is not None and str(value).strip() != "":
            return str(value).strip()
    return ""


def extract(config):
    awg = find_awg(config)
    if not isinstance(awg, dict):
        fail("VPN_LINK: контейнер amnezia-awg не найден")

    client = {}
    last_config = awg.get("last_config")
    if isinstance(last_config, str) and last_config.strip():
        try:
            parsed = json.loads(last_config)
            if isinstance(parsed, dict):
                client = parsed
        except Exception:
            client = {}

    native_conf = client.get("config")
    conf = parse_conf(native_conf) if isinstance(native_conf, str) else {}

    result = {}

    result["PRIVATE_KEY"] = first_nonempty(client.get("client_priv_key"), conf.get("PrivateKey"))
    result["PUBLIC_KEY"] = first_nonempty(client.get("server_pub_key"), conf.get("PublicKey"))
    result["PRESHARED_KEY"] = first_nonempty(client.get("psk_key"), conf.get("PresharedKey"))

    address = ipv4_only(conf.get("Address"))
    if not address:
        client_ip = first_nonempty(client.get("client_ip"))
        if client_ip:
            client_ip = client_ip.split(",")[0].strip()
            if "/" not in client_ip:
                client_ip += "/32"
            if IPV4_RE.match(client_ip):
                address = client_ip
    result["ADDRESS"] = address

    host = first_nonempty(client.get("hostName"), config.get("hostName"))
    port = first_nonempty(client.get("port"), awg.get("port"))
    if host and port:
        result["ENDPOINT"] = "%s:%s" % (host, port)
    else:
        result["ENDPOINT"] = conf.get("Endpoint", "")

    for key in ("Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4",
                "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5"):
        result[key] = first_nonempty(client.get(key), awg.get(key), conf.get(key))

    # DNS, MTU, keepalive и маршрутизация (AllowedIPs) намеренно не
    # экспортируются: их задаёт пользователь через конфиг (с project defaults).

    return result


def main():
    link = sys.stdin.read().strip()
    if not link:
        fail("VPN_LINK: пустая ссылка")
    for key, value in extract(decode_link(link)).items():
        print("%s=%s" % (key, value))


if __name__ == "__main__":
    main()
