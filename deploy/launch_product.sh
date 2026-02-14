#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "${SCRIPT_DIR}/launch_product.sh" "$@"
fi

bash "${SCRIPT_DIR}/install_arch_one_click.sh"

TARGET_ROOT="${TARGET_ROOT:-/opt/backlight-stack}"
ENV_FILE="${TARGET_ROOT}/deploy/.env"
LOCAL_NAME="backlight"
if [[ -f "${ENV_FILE}" ]]; then
  CANDIDATE="$(awk -F'=' '/^LOCAL_DASHBOARD_NAME=/{print $2}' "${ENV_FILE}" | tail -n1)"
  if [[ -n "${CANDIDATE}" ]]; then
    LOCAL_NAME="${CANDIDATE}"
  fi
fi

echo
echo "Product launch complete."
echo "Open dashboard from LAN: http://${LOCAL_NAME}.local"
