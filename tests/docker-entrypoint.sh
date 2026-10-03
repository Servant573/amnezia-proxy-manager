#!/bin/bash
set -euo pipefail
for file in amnezia-proxy-manager bin/amnezia-proxy lib/*.sh tests/*.sh; do
    bash -n "$file"
done
bash tests/run.sh
bash tests/security.sh
bash tests/behavior.sh
bash tests/ipv6.sh
bash tests/routes.sh
bash tests/sandbox-lifecycle.sh
bash tests/sandbox-environment.sh
python3 tests/sandbox-signals.py
python3 tests/sandbox-forwarder.py
python3 tests/sandbox-logging.py
python3 tests/healthcheck.py
python3 tests/processes.py
bash tests/netns.sh --container
bash tests/sandbox.sh --container
