"""Collapse IPv4 routes without adding or removing destination addresses."""
import ipaddress
import sys


def collapse_routes(lines):
    # The shell validator permits host bits in CIDRs; normalize them as AWG does.
    networks = [ipaddress.IPv4Network(line.strip(), strict=False)
                for line in lines if line.strip()]
    if not networks:
        raise ValueError("empty route list")
    return ipaddress.collapse_addresses(networks)


if __name__ == "__main__":
    try:
        routes = list(collapse_routes(sys.stdin))
    except ValueError as error:
        print(f"Cannot collapse IPv4 routes: {error}", file=sys.stderr)
        sys.exit(1)
    for route in routes:
        print(route)
