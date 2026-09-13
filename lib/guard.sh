#!/bin/bash

GUARD_OWNED=0

guard_is_active() {
    local table rules index tables
    [[ -f "$GUARD_FILE" ]] || return 1
    read -r table < "$GUARD_FILE" || return 1
    [[ "$table" =~ ^apm_${UID}_[0-9a-f]{32}$ ]] || return 1
    command -v python3 >/dev/null || return 2
    index=$(interface_index "$WG_INTERFACE") || return 1
    if ! rules=$(run_privileged nft -n -j list table inet "$table" 2>/dev/null); then
        tables=$(run_privileged nft list tables 2>/dev/null) || return 2
        grep -Fxq "table inet $table" <<< "$tables" || return 1
        return 2
    fi
    python3 "$PROJECT_ROOT/lib/check_guard.py" "$table" "$UID" "$PROXY_CONNECT_HOST" "$PROXY_PORT" "$index" <<< "$rules"
}

start_guard() {
    [[ ! -e "$GUARD_FILE" ]] || die "Осталось состояние сетевой защиты; сначала выполните stop"
    local token table index
    token=$(cat /proc/sys/kernel/random/uuid)
    table="apm_${UID}_${token//-/}"
    index=$(interface_index "$WG_INTERFACE")
    [[ "$index" =~ ^[0-9]+$ ]] && is_ipv4 "$PROXY_CONNECT_HOST" || return 1
    # Persist intent before installing the atomic ruleset: SIGKILL must never
    # leave an installed guard without its recovery information.
    printf '%s\n' "$table" > "$GUARD_FILE"
    GUARD_OWNED=1
    sudo nft -f - <<EOF
create table inet $table
add chain inet $table output { type filter hook output priority 0; policy accept; }
add rule inet $table output meta skuid $UID ip daddr $PROXY_CONNECT_HOST tcp dport $PROXY_PORT meta oif != $index counter drop
EOF
}

stop_guard() {
    [[ -f "$GUARD_FILE" ]] || return 0
    local table tables
    read -r table < "$GUARD_FILE" || return 1
    [[ "$table" =~ ^apm_${UID}_[0-9a-f]{32}$ ]] || return 1
    # Do not confuse an authorization failure with an absent table.
    tables=$(run_privileged nft list tables) || return 1
    if grep -Fxq "table inet $table" <<< "$tables"; then
        run_privileged nft delete table inet "$table" || return 1
    fi
    rm -f "$GUARD_FILE"
    GUARD_OWNED=0
}
