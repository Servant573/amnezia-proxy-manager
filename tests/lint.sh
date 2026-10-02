#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT_ROOT"
files=(amnezia-proxy-manager bin/amnezia-proxy lib/*.sh tests/*.sh)
for file in "${files[@]}"; do
    bash -n "$file"
done
# Modules exchange globals via source; checking each module independently
# cannot determine whether those variables are consumed by other modules.
shellcheck --severity=warning --external-sources --exclude=SC2034 "${files[@]}"
actionlint .github/workflows/ci.yml
echo 'OK: Bash syntax, ShellCheck and actionlint passed'
