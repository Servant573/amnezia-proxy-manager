#!/bin/bash
# GUI regressions: synthetic credentials, optional bwrap mounts, mocked manager.
# No sudo, display server or host network configuration changes.
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home"
export XDG_RUNTIME_DIR="$TEST_TMP/session"
export AMNEZIA_PROXY_STATE_DIR="$TEST_TMP/state"
export AMNEZIA_PROXY_CACHE_DIR="$TEST_TMP/cache"
export AMNEZIA_PROXY_CONFIG="$TEST_TMP/config with spaces"
unset AMNEZIA_PROXY_RUNTIME_DIR
mkdir -p "$HOME"
cp "$PROJECT_ROOT/tests/fixtures/valid.conf" "$AMNEZIA_PROXY_CONFIG"
source "$PROJECT_ROOT/bin/amnezia-proxy"
init_paths
load_config >/dev/null
fail() { echo "FAIL: $*" >&2; exit 1; }

ENDPOINT_CONNECT_HOST=198.51.100.1
ALLOWED_IPS=0.0.0.0/0
generate_wg_config >/dev/null
generate_proxy_config
read_active_proxy_ports
SANDBOX_HOST_IP=10.200.0.1
export DISPLAY=:0 XDG_SESSION_TYPE=x11
export XAUTHORITY="$TEST_TMP/xauth cookie"
printf 'synthetic-cookie' > "$XAUTHORITY"
printf 'session-resource' > "$XDG_RUNTIME_DIR/wayland-test"

if command -v bwrap >/dev/null && bwrap --ro-bind / / -- /bin/true 2>/dev/null; then
    for SANDBOX_GUI in 0 1; do
        sandbox_build_bwrap
        bwrap "${BWRAP_ARGS[@]}" -- /bin/bash -c '
            [[ ! -r "$1" && ! -r "$2" ]] || {
                echo "FAIL: generated VPN/upstream credentials exposed" >&2
                exit 1
            }
            if [[ "$3" == 1 ]]; then
                [[ "$(cat "$XAUTHORITY")" == synthetic-cookie ]] || exit 1
                [[ "$(cat "$XDG_RUNTIME_DIR/wayland-test")" == session-resource ]] || exit 1
            else
                [[ ! -r "$XAUTHORITY" && ! -e "$XDG_RUNTIME_DIR/wayland-test" ]] || exit 1
            fi
        ' _ "$WG_TMP_CONF" "$PROXY_CFG" "$SANDBOX_GUI"
    done
    echo 'OK: GUI hides runtime secrets, preserves session resources and mounts XAUTHORITY from /tmp'
else
    echo 'SKIP: GUI filesystem checks require bwrap and usable namespaces'
fi

# Use real CLI dispatch and port loading, replacing privileged lifecycle only.
# Copy the launcher so its relative manager path resolves to this test harness.
mock_root="$TEST_TMP/mock project"
mkdir -p "$mock_root/bin"
cp "$PROJECT_ROOT/bin/amnezia-proxy-gui" "$mock_root/bin/amnezia-proxy-gui"
cat > "$mock_root/amnezia-proxy-manager" <<'SH'
#!/bin/bash
set -euo pipefail
source "$GUI_TEST_PROJECT_ROOT/bin/amnezia-proxy"
init_paths() { :; }
do_run() {
    [[ "$SANDBOX_GUI" == 1 ]] || exit 1
    load_config >/dev/null
    [[ "$LOCAL_HTTP_PORT" == 8181 ]] || exit 1
    read_active_proxy_ports
    sandbox_addrs
    export HTTP_PROXY="http://${SANDBOX_HOST_IP}:${SANDBOX_HTTP_PORT}"
    exec "$@"
}
main "$@"
SH
chmod +x "$mock_root/amnezia-proxy-manager"
export GUI_TEST_PROJECT_ROOT="$PROJECT_ROOT"

# Active listener remains 8081; editing the user config must not change it.
awk '!/^[[:space:]]*LOCAL_HTTP_PORT[[:space:]]*=/' "$CONFIG_FILE" > "$TEST_TMP/config-new"
printf 'LOCAL_HTTP_PORT=8181\n' >> "$TEST_TMP/config-new"
mv "$TEST_TMP/config-new" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
export HTTP_PROXY=http://incorrect-caller-proxy:9999
for config_mode in default separate equals; do
    config_args=()
    case "$config_mode" in
        separate) config_args=( --config "$CONFIG_FILE" ) ;;
        equals) config_args=( "--config=$CONFIG_FILE" ) ;;
    esac
    bash "$mock_root/bin/amnezia-proxy-gui" "${config_args[@]}" -- \
        /bin/bash -c '
            [[ "$#" == 5 && "$1" == "argument with spaces" ]] || exit 1
            [[ "$2" == --no-sandbox ]] || exit 1
            [[ "$3" == --proxy-server=http://10.200.0.1:8081 ]] || exit 1
            [[ "$4" == --disable-quic ]] || exit 1
            [[ "$5" == --force-webrtc-ip-handling-policy=disable_non_proxied_udp ]] || exit 1
        ' application 'argument with spaces' || fail "launcher failed ($config_mode config)"
done
echo 'OK: GUI launcher uses active runtime proxy and preserves command/config arguments'
