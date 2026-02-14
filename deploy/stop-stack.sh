#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Try tunnel profile first, then regular stack.
/usr/bin/docker compose --profile tunnel down || true
/usr/bin/docker compose --profile quicktunnel down || true
/usr/bin/docker compose down || true
