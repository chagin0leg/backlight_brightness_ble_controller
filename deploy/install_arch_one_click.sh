#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash deploy/install_arch_one_click.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_ROOT="${TARGET_ROOT:-/opt/backlight-stack}"
TARGET_DEPLOY="${TARGET_ROOT}/deploy"

echo "[1/7] Installing base packages..."
pacman -Syu --noconfirm docker docker-compose rsync avahi nss-mdns

if [[ "${INSTALL_CLOUDFLARED:-1}" == "1" ]]; then
  pacman -S --noconfirm cloudflared
fi

echo "[2/7] Enabling Docker and mDNS services..."
systemctl enable --now docker
systemctl enable --now avahi-daemon

echo "[3/7] Copying deploy assets..."
mkdir -p "${TARGET_ROOT}"
rsync -a --delete "${SCRIPT_DIR}/" "${TARGET_DEPLOY}/"

echo "[4/7] Preparing environment file..."
if [[ ! -f "${TARGET_DEPLOY}/.env" ]]; then
  cp "${TARGET_DEPLOY}/.env.example" "${TARGET_DEPLOY}/.env"
fi

LOCAL_DASHBOARD_NAME="$(awk -F'=' '/^LOCAL_DASHBOARD_NAME=/{print $2}' "${TARGET_DEPLOY}/.env" | tail -n1)"
if [[ -z "${LOCAL_DASHBOARD_NAME}" ]]; then
  LOCAL_DASHBOARD_NAME="backlight"
fi

if [[ "${APPLY_MDNS_HOSTNAME:-1}" == "1" ]]; then
  echo "Applying local hostname: ${LOCAL_DASHBOARD_NAME}"
  hostnamectl set-hostname "${LOCAL_DASHBOARD_NAME}"
fi

if ! grep -q "mdns_minimal" /etc/nsswitch.conf; then
  sed -i 's/^hosts:.*/hosts: files mdns_minimal [NOTFOUND=return] dns myhostname/' /etc/nsswitch.conf || true
fi

echo "[5/7] Installing systemd units..."
install -m 0644 "${TARGET_DEPLOY}/systemd/backlight-stack.service" /etc/systemd/system/backlight-stack.service
install -m 0644 "${TARGET_DEPLOY}/systemd/backlight-hil.service" /etc/systemd/system/backlight-hil.service
if [[ "${INSTALL_CLOUDFLARED:-1}" == "1" ]]; then
  install -m 0644 "${TARGET_DEPLOY}/systemd/backlight-cloudflared.service" /etc/systemd/system/backlight-cloudflared.service
fi

echo "[6/7] Reloading systemd and starting stack..."
systemctl daemon-reload
systemctl enable --now backlight-stack.service

if [[ "${ENABLE_CLOUDFLARED_SERVICE:-0}" == "1" ]]; then
  systemctl enable --now backlight-cloudflared.service || true
fi

if [[ "${ENABLE_HIL_SERVICE:-0}" == "1" ]]; then
  systemctl enable --now backlight-hil.service || true
fi

echo "[7/7] Done."
echo "Edit ${TARGET_DEPLOY}/.env and restart stack:"
echo "  sudo systemctl restart backlight-stack.service"
echo "Local dashboard:"
echo "  http://${LOCAL_DASHBOARD_NAME}.local"
echo "Health check:"
echo "  curl -sSf http://${LOCAL_DASHBOARD_NAME}.local/health"
