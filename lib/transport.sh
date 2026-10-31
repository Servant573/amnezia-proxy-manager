#!/bin/bash

# Coupling only: VPN and proxy lifecycle remain independent.
transport_verify_route() {
    local route
    route=$(route_for_ipv4 "$PROXY_CONNECT_HOST") || die "Нет маршрута к upstream-прокси $PROXY_CONNECT_HOST"
    if ! route_uses_interface "$route" "$WG_INTERFACE"; then
        die "Upstream-прокси $PROXY_CONNECT_HOST маршрутизируется вне $WG_INTERFACE"
    fi
    log INFO "Маршрут к upstream: $route"
}

prepare_network_targets() {
    if (( ${PROXY_ON:-1} )); then proxy_prepare_upstream; fi
    if (( ${VPN_ON:-1} )); then vpn_prepare_endpoint; fi
}

# Only the composition layer contributes upstream addresses to VPN routes.
transport_extra_routes() {
    if (( VPN_ON && PROXY_ON )); then printf '%s' "$PROXY_IPS"; fi
    return 0
}
