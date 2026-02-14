#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [[ -n "${CLOUDFLARED_TOKEN:-}" ]]; then
  exec /usr/bin/docker compose --profile tunnel up -d --remove-orphans
fi

exec /usr/bin/docker compose up -d --remove-orphans
