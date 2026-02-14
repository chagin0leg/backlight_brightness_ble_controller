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

is_true() {
  local raw="${1:-}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  [[ "${raw}" == "1" || "${raw}" == "true" || "${raw}" == "yes" || "${raw}" == "on" ]]
}

if [[ -n "${CLOUDFLARED_TOKEN:-}" ]]; then
  exec /usr/bin/docker compose --profile tunnel up -d --remove-orphans
fi

if is_true "${ENABLE_TRYCLOUDFLARE:-true}"; then
  exec /usr/bin/docker compose --profile quicktunnel up -d --remove-orphans
fi

exec /usr/bin/docker compose up -d --remove-orphans
