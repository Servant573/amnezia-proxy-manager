#!/bin/bash
set -euo pipefail
for file in amnezia-proxy-manager bin/amnezia-proxy bin/amnezia-proxy-gui lib/*.sh tests/*.sh; do
    bash -n "$file"
done
bash tests/run.sh
bash tests/component-modes.sh
bash tests/security.sh
bash tests/behavior.sh
bash tests/ipv6.sh
bash tests/routes.sh
python3 tests/route-collapse.py
bash tests/sandbox-lifecycle.sh
bash tests/sandbox-environment.sh
bash tests/sandbox-gui.sh
python3 tests/sandbox-signals.py
python3 tests/sandbox-forwarder.py
python3 tests/sandbox-logging.py
python3 tests/healthcheck.py
python3 tests/processes.py
python3 tests/component-lifecycle.py
python3 tests/component-failures.py
python3 tests/vpn-connect.py
bash tests/netns.sh --container
bash tests/sandbox.sh --container
