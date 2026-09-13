#!/bin/bash
set -euo pipefail
for file in amnezia-proxy-manager bin/amnezia-proxy lib/*.sh tests/*.sh; do
    bash -n "$file"
done
bash tests/run.sh
bash tests/security.sh
bash tests/behavior.sh
bash tests/ipv6.sh
python3 tests/healthcheck.py
python3 tests/processes.py
bash tests/netns.sh --container
