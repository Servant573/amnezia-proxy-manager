#!/bin/bash

IPV6_OWNED=0

ipv6_block_active() {
    local table rules tables
    [[ -f "$IPV6_GUARD_FILE" ]] || return 1
    read -r table < "$IPV6_GUARD_FILE" || return 1
    [[ "$table" =~ ^apm6_${UID}_[0-9a-f]{32}$ ]] || return 1
    command -v python3 >/dev/null || return 2
    if ! rules=$(run_privileged nft -n -j list table ip6 "$table" 2>/dev/null); then
        tables=$(run_privileged nft list tables 2>/dev/null) || return 2
        grep -Fxq "table ip6 $table" <<< "$tables" || return 1
        return 2
    fi
    python3 "$PROJECT_ROOT/lib/check_ipv6_guard.py" "$table" <<< "$rules"
}

block_ipv6() {
    [[ ! -e "$IPV6_GUARD_FILE" ]] || die "Осталась IPv6-защита предыдущего запуска; сначала выполните stop"
    if [[ "$BLOCK_IPV6" == off ]]; then
        log WARN "BLOCK_IPV6=off: менеджер не блокирует прямой IPv6; защита от обхода VPN по IPv6 не обеспечена"
        return 0
    fi
    [[ "$BLOCK_IPV6" == on ]] || return 1
    local token table
    token=$(cat /proc/sys/kernel/random/uuid) || return 1
    table="apm6_${UID}_${token//-/}"
    [[ "$table" =~ ^apm6_${UID}_[0-9a-f]{32}$ ]] || return 1
    # Intent survives SIGKILL; the batch creates the table and rule atomically.
    printf '%s\n' "$table" > "$IPV6_GUARD_FILE" || return 1
    IPV6_OWNED=1
    log INFO "Блокирую исходящий IPv6 всех локальных процессов, кроме loopback"
    sudo nft -f - <<EOF
create table ip6 $table
add chain ip6 $table output { type filter hook output priority 0; policy accept; }
add rule ip6 $table output meta oifname != "lo" counter reject with icmpv6 type admin-prohibited
EOF
}

unblock_ipv6() {
    [[ -f "$IPV6_GUARD_FILE" ]] || return 0
    local table tables
    read -r table < "$IPV6_GUARD_FILE" || return 1
    [[ "$table" =~ ^apm6_${UID}_[0-9a-f]{32}$ ]] || return 1
    tables=$(run_privileged nft list tables) || return 1
    if grep -Fxq "table ip6 $table" <<< "$tables"; then
        run_privileged nft delete table ip6 "$table" || return 1
    fi
    rm -f "$IPV6_GUARD_FILE"
    IPV6_OWNED=0
    log OK "Собственная блокировка IPv6 снята"
}
