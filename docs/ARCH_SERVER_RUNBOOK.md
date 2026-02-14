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

- Reverse proxy: Caddy or Nginx
- App API: lightweight runtime (Go/FastAPI/Node)
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

## 7. Scaling path

1. Start with tunnel + single node.
2. Move profile manifest to CDN/object storage.
3. Keep auth and diagnostics endpoints stateless.
4. Add managed DB only if truly required.
