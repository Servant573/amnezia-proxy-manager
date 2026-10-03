#!/bin/bash
# No sudo, mounts or network mutations: emulate bwrap's --setenv after env reset.
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
export AMNEZIA_PROXY_RUNTIME_DIR="$TEST_TMP/runtime"
export AMNEZIA_PROXY_STATE_DIR="$TEST_TMP/state"
export AMNEZIA_PROXY_CACHE_DIR="$TEST_TMP/cache"
export AMNEZIA_PROXY_CONFIG="$PROJECT_ROOT/tests/fixtures/valid.conf"
source "$PROJECT_ROOT/bin/amnezia-proxy"
init_paths
load_config >/dev/null

mkdir -p "$TEST_TMP/user bin"
ln -s /usr/bin/true "$TEST_TMP/user bin/claude"
export PATH="$TEST_TMP/user bin:$PATH"
# Login identity must come from the invoking UID, not spoofable env variables.
export USER=wrong-user LOGNAME=wrong-login
SANDBOX_HOST_IP=10.200.0.1
SANDBOX_HTTP_PORT=8081
SANDBOX_SOCKS_PORT=1080
sandbox_build_bwrap

agent_env=()
for ((i=0; i<${#BWRAP_ARGS[@]}; i++)); do
    if [[ "${BWRAP_ARGS[i]}" == --setenv ]]; then
        agent_env+=( "${BWRAP_ARGS[i+1]}=${BWRAP_ARGS[i+2]}" )
        i=$((i+2))
    fi
done
expected_user=$(id -un "$UID")
# env -i models a launcher which discarded the caller's entire environment.
/usr/bin/env -i "${agent_env[@]}" /bin/bash -c '
    [[ "$PATH" == "$1" && "$HOME" == "$2" ]] || exit 1
    [[ "$USER" == "$3" && "$LOGNAME" == "$3" ]] || exit 1
    [[ "$HTTP_PROXY" == http://10.200.0.1:8081 ]] || exit 1
    [[ "$(command -v claude)" == "$4/user bin/claude" ]] || exit 1
    claude
' _ "$PATH" "$HOME" "$expected_user" "$TEST_TMP"
echo 'OK: user PATH/HOME and UID identity survive launcher environment reset'
