#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

exec /usr/bin/docker compose -f docker-compose.yml -f hil/docker-compose.hil.yml down
