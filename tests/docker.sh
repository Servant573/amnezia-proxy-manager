#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=amnezia-proxy-manager-tests:local
docker build -f "$PROJECT_ROOT/tests/Dockerfile" -t "$image" "$PROJECT_ROOT"
docker run --rm --network none --cap-drop ALL --cap-add NET_ADMIN \
    --security-opt no-new-privileges --read-only \
    --tmpfs /tmp:rw,exec,nosuid,nodev,size=64m "$image"
