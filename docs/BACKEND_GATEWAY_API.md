# Headless Gateway API (Self-Hosted)

This gateway is implemented in `deploy/gateway/app.py` and is designed for low-resource deployments.

## Security and privacy defaults

- No external dependencies.
- PII-like keys are redacted from diagnostics payloads before persistence.
- OAuth callback endpoint avoids logging query secrets.
- Telegram verification returns hashed subject, not raw Telegram profile data.
- Local web console endpoints are restricted to local-network clients.

## Endpoints

## `GET /ui`

Local web console for headless setup and product dashboard.

Access policy:
- allowed only from local/private/link-local/loopback networks
- expected local URL: `http://<name>.local`

## `GET /ui/api/status`

Returns setup checklist, runtime status, and auth/diagnostics metrics.

## `POST /ui/api/config/google`

Updates runtime Google config and dashboard local-name settings.

## `GET /health`

Returns service status and UTC time.

Example response:

```json
{
  "ok": true,
  "service": "gateway",
  "time_utc": "2026-02-14T12:34:56.000000+00:00"
}
```

## `GET /auth/callback`

Query params:
- `provider` (optional)
- `code` (optional)
- `state` (optional)
- `error` (optional)

Behavior:
- Generates short-lived auth ticket (5 minutes).
- Does not expose or store raw OAuth token exchange output.
- If `state` matches a device-auth session, marks it completed/failed.

## `GET /auth/ticket?ticket=...`

Returns callback metadata for short-lived ticket.

## `POST /auth/device/start`

Starts device authorization session for client polling flow.

Request body:

```json
{
  "provider": "google",
  "external_auth_url": "https://example.com/oauth/start"
}
```

Behavior:
- Creates short-lived session id.
- Builds provider URL with `state=<session_id>` when possible.
- Returns `auth_url` for browser login.

## `GET /auth/device/status?session_id=...`

Returns status of device auth session:
- `pending`
- `completed`
- `failed`
- `expired`

## `GET /auth/google/start`

Starts Google OAuth flow.

Query params:
- `state` (optional, if omitted generated automatically)
- `mode=json` (optional; returns auth URL JSON instead of redirect)

## `GET /auth/google/callback`

Handles Google OAuth callback:
- exchanges authorization code
- verifies ID token (`tokeninfo`)
- maps user to anonymous hashed subject
- updates device session when `state` is present

## `POST /auth/telegram/verify`

Accepts Telegram Login Widget payload JSON and validates hash using `TELEGRAM_BOT_TOKEN`.

Required payload fields include:
- `id`
- `auth_date`
- `hash`

Response includes:
- `provider`
- hashed `subject`
- `auth_age_sec`

Optional input:
- `state` (if provided and matches active device session, marks session completed)

## `POST /diagnostics/ingest`

Accepts JSON diagnostics payload.

Optional protection:
- `X-API-Key` header when `DIAGNOSTICS_INGEST_API_KEY` is configured.

Storage:
- Files are written under `/data/diagnostics/YYYY-MM-DD/<event_id>.json`

## `GET /profiles/manifest`

Serves optional profile manifest from:
- `/data/profiles/manifest.json`

Useful as a lightweight profile update source for app clients.

## Environment variables

- `GATEWAY_HOST` (default `0.0.0.0`)
- `GATEWAY_PORT` (default `8080`)
- `DATA_DIR` (default `/data`)
- `MAX_BODY_BYTES` (default `1048576`)
- `TELEGRAM_BOT_TOKEN`
- `AUTH_SUBJECT_SALT`
- `DIAGNOSTICS_INGEST_API_KEY` (optional)
- `APP_REDIRECT_BASE` (optional hint for auth callback redirect)
- `AUTH_DEVICE_SESSION_TTL_SEC` (default `300`)
- `LOCAL_DASHBOARD_NAME` (default `backlight`)
- `GOOGLE_AUTH_ENABLED`
- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `GOOGLE_REDIRECT_URI`
- `GOOGLE_SCOPE` (default `openid email profile`)
- `GOOGLE_PROMPT` (default `consent`)
- `GOOGLE_ALLOWED_DOMAIN` (optional)
- `GOOGLE_REQUIRE_VERIFIED_EMAIL` (default `true`)
