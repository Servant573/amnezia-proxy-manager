#!/bin/bash

SESSION_OWNED=0
SESSION_KEYS='SESSION_ID SESSION_PHASE VPN_ON PROXY_ON BLOCK_IPV6 WG_INTERFACE WG_MTU HEALTHCHECK_URL SANDBOX_NETNS_NAME SANDBOX_VETH_SUBNET SANDBOX_HIDE_PATHS SANDBOX_NO_PROXY SANDBOX_EXPECTED_EXIT_IP'

session_write() {
    local tmp key
    SESSION_PHASE=${1:-starting}
    SESSION_ID=${SESSION_ID:-$(cat /proc/sys/kernel/random/uuid)}
    tmp=$(mktemp "$RUNTIME_DIR/session.XXXXXX") || return 1
    ( umask 077
      printf 'version=1\n'
      for key in $SESSION_KEYS; do printf '%s=%s\n' "$key" "${!key-}"; done
    ) > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f -- "$tmp" "$SESSION_FILE" || { rm -f "$tmp"; return 1; }
    SESSION_OWNED=1
}

# Parse data, never shell source. Commit globals only after full validation.
session_load() {
    local line key value count=0
    local -A values=()
    [[ -f "$SESSION_FILE" && ! -L "$SESSION_FILE" && -O "$SESSION_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* && "$line" != *[[:cntrl:]]* ]] || return 1
        key=${line%%=*}; value=${line#*=}
        [[ " version $SESSION_KEYS " == *" $key "* && -z "${values[$key]+set}" ]] || return 1
        values[$key]=$value
        count=$((count+1))
    done < "$SESSION_FILE"
    [[ "$count" == 14 && "${values[version]:-}" == 1 ]] || return 1
    [[ "${values[VPN_ON]:-}" =~ ^[01]$ && "${values[PROXY_ON]:-}" =~ ^[01]$ ]] || return 1
    [[ "${values[BLOCK_IPV6]:-}" == on || "${values[BLOCK_IPV6]:-}" == off ]] || return 1
    for key in $SESSION_KEYS; do [[ -n "${values[$key]+set}" ]] || return 1; done
    [[ "${values[SESSION_ID]}" =~ ^[0-9a-f-]{36}$ ]] || return 1
    [[ "${values[SESSION_PHASE]}" == starting || "${values[SESSION_PHASE]}" == ready ]] || return 1
    (( values[VPN_ON] || values[PROXY_ON] )) || return 1
    if (( values[VPN_ON] )); then
        [[ "${values[WG_INTERFACE]}" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ && "${values[WG_INTERFACE]}" != . && "${values[WG_INTERFACE]}" != .. ]] || return 1
    fi
    (
        for key in $SESSION_KEYS; do printf -v "$key" '%s' "${values[$key]}"; done
        LOG_TO_FILE=0
        STARTUP_HEALTHCHECK=off
        if (( PROXY_ON )); then validate_sandbox_config; fi
        if (( VPN_ON )); then
            [[ "$WG_MTU" == auto ]] || is_uint_between "$WG_MTU" 576 9000 || exit 1
        fi
    ) || return 1
    for key in $SESSION_KEYS; do printf -v "$key" '%s' "${values[$key]}"; done
    WG_TMP_CONF="$RUNTIME_DIR/$WG_INTERFACE.conf"
}
