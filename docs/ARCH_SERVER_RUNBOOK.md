# Arch Linux Lightweight Server Runbook

This runbook targets a low-power self-hosted node:

- CPU: 2 cores
- RAM: 16 GB
- Network: internet access via mobile carrier, no dedicated public IP

## 1. Topology

Use outbound tunnel-first networking:

- App users -> public hostname -> tunnel edge -> Arch server
- No inbound port forwarding required
- Preferred: Cloudflare Tunnel

## 2. Minimum service set

- Reverse proxy: Caddy
- App API: lightweight Python gateway (included in `deploy/gateway/app.py`)
- Optional metadata: SQLite
- Process supervisor: systemd

## 3. Responsibilities of this server

- OAuth callback handling for providers that need custom flow.
- Telegram signature/hash verification endpoint.
- Diagnostics ingest endpoint (anonymous payload only).
- Optional profile manifest proxy/cache.

## 4. What should stay off this server

- Heavy analytics processing
- ML inference
- Long-running batch jobs

Use serverless/free-tier backends for heavy or bursty tasks.

## 5. Reliability guardrails

- systemd restart policy for all critical services
- simple `/health` endpoint
- disk usage guardrail and log rotation
- fallback mode in app when server is unavailable

## 6. Security baseline

- TLS termination at public edge (tunnel/provider)
- Secret management through environment variables
- deny-list sensitive fields in request body logs
- no PII persistence by default

## 7. Included deployment templates

The repository includes ready templates:

- `deploy/docker-compose.yml`
- `deploy/.env.example`
- `deploy/caddy/Caddyfile`
- `deploy/cloudflared/config.yml`
- `deploy/systemd/backlight-stack.service`
- `deploy/systemd/backlight-cloudflared.service`
- `deploy/gateway/app.py`

## 8. Quick start on Arch Linux

### One-button install (recommended)

From repository root on server:

```bash
sudo bash deploy/install_arch_one_click.sh
```

What it does:
- installs required packages
- copies deploy templates to `/opt/backlight-stack/deploy`
- installs systemd units
- starts `backlight-stack.service`

Optional flags:
- `INSTALL_CLOUDFLARED=1` (default)
- `ENABLE_CLOUDFLARED_SERVICE=1` (disabled by default)
- `ENABLE_HIL_SERVICE=1` (disabled by default)
- `TARGET_ROOT=/opt/backlight-stack` (default)

### Manual install (advanced)

1. Install base packages:

```bash
sudo pacman -Syu --noconfirm docker docker-compose cloudflared
sudo systemctl enable --now docker
```

2. Copy project to server (example path):

```bash
sudo mkdir -p /opt/backlight-stack
sudo chown -R "$USER":"$USER" /opt/backlight-stack
```

3. Prepare environment:

```bash
cp /opt/backlight-stack/deploy/.env.example /opt/backlight-stack/deploy/.env
```

Set at least:
- `AUTH_SUBJECT_SALT`
- `TELEGRAM_BOT_TOKEN` (if Telegram is used)
- optional `DIAGNOSTICS_INGEST_API_KEY`

4. Start stack via systemd:

```bash
sudo cp /opt/backlight-stack/deploy/systemd/backlight-stack.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now backlight-stack.service
```

5. Enable Cloudflare tunnel (optional, recommended when no public IP):

- Fill tunnel UUID/credentials in `/opt/backlight-stack/deploy/cloudflared/config.yml`
- Then:

```bash
sudo cp /opt/backlight-stack/deploy/systemd/backlight-cloudflared.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now backlight-cloudflared.service
```

## 9. Gateway endpoint summary

- `GET /health` - service health
- `GET /auth/callback` - OAuth callback relay (code is not logged)
- `GET /auth/ticket?ticket=...` - short-lived callback ticket fetch
- `POST /auth/telegram/verify` - Telegram hash verification
- `POST /diagnostics/ingest` - anonymous diagnostics ingest (PII keys redacted)
- `GET /profiles/manifest` - optional profile manifest from local storage

## 10. HIL stand support on same Arch node

Included HIL templates:

- `deploy/hil/docker-compose.hil.yml`
- `deploy/systemd/backlight-hil.service`

Start HIL service:

```bash
sudo systemctl enable --now backlight-hil.service
```

Or run manually:

```bash
cd /opt/backlight-stack/deploy
sudo bash run-hil.sh
```

## 11. Scaling path

1. Start with tunnel + single node.
2. Move profile manifest to CDN/object storage.
3. Keep auth and diagnostics endpoints stateless.
4. Add managed DB only if truly required.
