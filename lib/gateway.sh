#!/bin/bash

GATEWAY_OWNED=0
GATEWAY_ROUTE_TABLE=28642
GATEWAY_RULE_PRIORITY=11000
GATEWAY_ROUTE_PROTO=242
GATEWAY_TUNNEL_MARK=0x41504d01
GATEWAY_DIRECT_MARK=0x41504d02

gateway_firewall() {
    cat <<EOF
table inet apm_gateway {
    chain permit {
    }
    chain input {
        type filter hook input priority 0; policy accept;
        iifname "$GATEWAY_INGRESS_IF" drop
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
        iifname "$GATEWAY_INGRESS_IF" jump permit
        iifname "$GATEWAY_INGRESS_IF" drop
        oifname "$GATEWAY_INGRESS_IF" jump permit
        oifname "$GATEWAY_INGRESS_IF" drop
    }
}
EOF
}

gateway_cidrs() {
    local source raw line item count
    local -a items cidrs=()
    for source in inline $GATEWAY_CIDR_URLS; do
        if [[ "$source" == inline ]]; then
            raw="$GATEWAY_CIDRS"
        else
            raw=$(curl -q -fsSL --proto '=https' --proto-redir '=https' --max-time 45 --connect-timeout 10 -- "$source") \
                || die "Не удалось загрузить список шлюза $source" >&2
        fi
        count=0
        while IFS= read -r line; do
            line="${line%$'\r'}"
            line="${line%%#*}"
            read -ra items <<< "${line//,/ }"
            for item in "${items[@]}"; do
                if is_ipv4 "$item"; then item="$item/32"; fi
                is_ipv4_cidr "$item" || die "Список шлюза ($source) содержит невалидный IPv4/CIDR" >&2
                cidrs+=("$item")
                count=$((count + 1))
            done
        done <<< "$raw"
        [[ "$source" == inline || "$count" -gt 0 ]] || die "Список шлюза $source пуст" >&2
    done
    if (( ${#cidrs[@]} )); then
        printf '%s\n' "${cidrs[@]}" | python3 "$PROJECT_ROOT/lib/collapse_routes.py" | paste -sd, -
    fi
}

gateway_routes() {
    ip -o -N -4 route show table all | awk -v table="$GATEWAY_ROUTE_TABLE" '
        { for (i=1; i<NF; i++) if ($i == "table" && $(i+1) == table) print }
    '
}

gateway_policy_rule() {
    ip -N -4 rule show pref "$GATEWAY_RULE_PRIORITY" iif "$1" fwmark "$GATEWAY_TUNNEL_MARK" \
        lookup "$GATEWAY_ROUTE_TABLE" protocol "$GATEWAY_ROUTE_PROTO"
}

gateway_record() {
    local tmp
    tmp=$(mktemp "$RUNTIME_DIR/gateway.XXXXXX") || return 1
    if ! printf '%s %s %s %s\n' "$SESSION_ID" "$gateway_boot" "$GATEWAY_INGRESS_IF" "$1" > "$tmp" ||
        ! mv -f -- "$tmp" "$GATEWAY_FILE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

gateway_prepare() {
    local actual expected gateway_boot
    [[ $(< /proc/sys/net/ipv4/ip_forward) == 1 ]] || die 'Включите net.ipv4.ip_forward на сервере шлюза'
    interface_index "$GATEWAY_INGRESS_IF" >/dev/null || die "Входящий интерфейс $GATEWAY_INGRESS_IF отсутствует"
    interface_index "$GATEWAY_WAN_IF" >/dev/null || die "WAN-интерфейс $GATEWAY_WAN_IF отсутствует"
    actual=$(run_privileged nft -s -n -y list table inet apm_gateway) \
        || die 'Загрузите базовые правила из apm gateway firewall'
    expected=$(gateway_firewall)
    [[ "${actual//[[:space:]]/}" == "${expected//[[:space:]]/}" ]] \
        || die 'Таблица apm_gateway занята или отличается от базовых правил apm gateway firewall'
    gateway_boot=$(cat /proc/sys/kernel/random/boot_id) || return 1
    gateway_record 0 || return 1
    GATEWAY_OWNED=1
    run_privileged nft -f - <<EOF
create chain inet apm_gateway apm_session { comment "apm-$SESSION_ID"; }
EOF
}

gateway_classify_rule() {
    local match="$1" verdict
    case "$2" in
        block) verdict='drop' ;;
        direct) verdict="meta mark set $GATEWAY_DIRECT_MARK return" ;;
        tunnel) verdict="meta mark set $GATEWAY_TUNNEL_MARK return" ;;
    esac
    printf 'add rule inet apm_gateway classify meta iif %s %s %s\n' "$gateway_ingress_index" "$match" "$verdict"
}

gateway_egress_rules() {
    local interface="$1" mark="$2" action="$3" reply_match=''
    if [[ "$GATEWAY_MATCH_ACTION" != "$GATEWAY_DEFAULT_ACTION" ]]; then
        if [[ "$action" == "$GATEWAY_MATCH_ACTION" ]]; then reply_match='ct original ip daddr @destinations'
        else reply_match='ct original ip daddr != @destinations'; fi
    fi
    cat <<EOF
add rule inet apm_gateway permit meta nfproto ipv4 meta iif $gateway_ingress_index meta oif $interface meta mark $mark counter accept
add rule inet apm_gateway permit meta nfproto ipv4 meta iif $interface meta oif $gateway_ingress_index ct direction reply ct state established,related $reply_match counter accept
add rule inet apm_gateway source_nat meta iif $gateway_ingress_index meta oif $interface meta mark $mark masquerade
EOF
}

gateway_activate() {
    local gateway_ingress_index wan_index tunnel_index gateway_boot rules routes prefixes="$1"
    gateway_ingress_index=$(interface_index "$GATEWAY_INGRESS_IF") || return 1
    wan_index=$(interface_index "$GATEWAY_WAN_IF") || return 1
    if (( VPN_ON )); then
        tunnel_index=$(interface_index "$WG_INTERFACE") || return 1
        rules=$(ip -4 rule show pref "$GATEWAY_RULE_PRIORITY") || return 1
        routes=$(gateway_routes) || return 1
        [[ -z "$rules" && -z "$routes" ]] || die 'Таблица или приоритет маршрутизации шлюза уже заняты'
        gateway_boot=$(cat /proc/sys/kernel/random/boot_id) || return 1
        gateway_record 1 || return 1
        run_privileged ip -4 route add unreachable default metric 32767 table "$GATEWAY_ROUTE_TABLE" proto "$GATEWAY_ROUTE_PROTO" || return 1
        run_privileged ip -4 route add default dev "$WG_INTERFACE" table "$GATEWAY_ROUTE_TABLE" proto "$GATEWAY_ROUTE_PROTO" || return 1
        run_privileged ip -4 rule add pref "$GATEWAY_RULE_PRIORITY" iif "$GATEWAY_INGRESS_IF" fwmark "$GATEWAY_TUNNEL_MARK" \
            lookup "$GATEWAY_ROUTE_TABLE" protocol "$GATEWAY_ROUTE_PROTO" || return 1
    fi
    {
        cat <<EOF
create set inet apm_gateway destinations { type ipv4_addr; flags interval; }
create chain inet apm_gateway classify { type filter hook prerouting priority -90; policy accept; }
create chain inet apm_gateway source_nat { type nat hook postrouting priority 95; policy accept; }
add rule inet apm_gateway classify meta iif $gateway_ingress_index ip daddr 169.254.0.0/16 drop
EOF
        if [[ -n "$prefixes" ]]; then
            printf 'add element inet apm_gateway destinations { %s }\n' "$prefixes"
            gateway_classify_rule 'ip daddr @destinations' "$GATEWAY_MATCH_ACTION"
        fi
        gateway_classify_rule 'meta nfproto ipv4' "$GATEWAY_DEFAULT_ACTION"
        if [[ "$GATEWAY_MATCH_ACTION" == direct || "$GATEWAY_DEFAULT_ACTION" == direct ]]; then
            gateway_egress_rules "$wan_index" "$GATEWAY_DIRECT_MARK" direct
        fi
        if (( VPN_ON )); then gateway_egress_rules "$tunnel_index" "$GATEWAY_TUNNEL_MARK" tunnel; fi
    } | run_privileged nft -f -
}

gateway_is_active() {
    local owner table
    read -r owner _ < "$GATEWAY_FILE" || return 1
    [[ "$owner" == "$SESSION_ID" ]] || return 1
    table=$(run_privileged nft -t list table inet apm_gateway) || return 1
    [[ "$table" == *"comment \"apm-$owner\""* && "$table" == *'chain classify {'* && "$table" == *'chain source_nat {'* ]]
}

stop_gateway() {
    [[ -e "$GATEWAY_FILE" ]] || return 0
    local owner boot ingress routed current_boot tables table rules routes
    read -r owner boot ingress routed < "$GATEWAY_FILE" || return 1
    [[ "$owner" =~ ^[0-9a-f-]{36}$ && "$boot" =~ ^[0-9a-f-]{36}$ && "$routed" =~ ^[01]$ ]] && valid_interface_name "$ingress" || return 1
    current_boot=$(cat /proc/sys/kernel/random/boot_id) || return 1
    if [[ "$boot" == "$current_boot" ]]; then
        tables=$(run_privileged nft list tables) || return 1
        if grep -Fxq 'table inet apm_gateway' <<< "$tables"; then
            table=$(run_privileged nft -t list table inet apm_gateway) || return 1
            if [[ "$table" == *"comment \"apm-$owner\""* ]]; then
                {
                    echo 'flush chain inet apm_gateway permit'
                    if [[ "$table" == *'chain classify {'* ]]; then echo 'delete chain inet apm_gateway classify'; fi
                    if [[ "$table" == *'chain source_nat {'* ]]; then echo 'delete chain inet apm_gateway source_nat'; fi
                    if [[ "$table" == *'set destinations {'* ]]; then echo 'delete set inet apm_gateway destinations'; fi
                } | run_privileged nft -f - || return 1
            elif [[ "$table" == *'chain apm_session {'* ]]; then
                # An exclusive claim that lost the race owns no host resources.
                (( ! routed )) || return 1
                rm -f -- "$GATEWAY_FILE"
                return
            fi
        fi
        if (( routed )); then
            rules=$(gateway_policy_rule "$ingress") || return 1
            if [[ -n "$rules" ]]; then
                run_privileged ip -4 rule del pref "$GATEWAY_RULE_PRIORITY" iif "$ingress" fwmark "$GATEWAY_TUNNEL_MARK" \
                    lookup "$GATEWAY_ROUTE_TABLE" protocol "$GATEWAY_ROUTE_PROTO" || return 1
            fi
            routes=$(gateway_routes) || return 1
            if [[ -n "$routes" ]]; then
                run_privileged ip -4 route flush table "$GATEWAY_ROUTE_TABLE" proto "$GATEWAY_ROUTE_PROTO" || return 1
            fi
        fi
        if [[ "${table:-}" == *"comment \"apm-$owner\""* ]]; then
            run_privileged nft delete chain inet apm_gateway apm_session || return 1
        fi
    fi
    rm -f -- "$GATEWAY_FILE" || return 1
    GATEWAY_OWNED=0
}
